import LinkPresentation
import SwiftUI
import UIKit

/// An album or song link, handed to the share sheet with a preview card that
/// has both the page's own billing *and* the cover already on this device.
///
/// Getting both took three attempts, so the reasoning is worth keeping.
///
/// What the card says is not something an app can set: `LPLinkMetadata` exposes
/// a `title` and no subtitle. A song's artist line appears because Apple, when
/// it *fetches* a page, follows `music:musician` and renders that page's
/// `<title>` underneath. An album's page can't use that — `music:musician` only
/// works under `og:type` `music.song`, and iMessage then presents the album as
/// a track — so it writes "<name> - Album by <artist>" into `og:title` and
/// takes the plain card. Either way the wording lives on the page, and a
/// hand-built `LPLinkMetadata` replaces the fetched card wholesale, silently
/// costing it.
///
/// The cover has the opposite problem. `og:image` is read by an
/// unauthenticated fetcher, so art inside a restricted Drive folder is
/// invisible to it, and OneDrive has no anonymous thumbnail at all.
///
/// The resolution is to do both: fetch the metadata so Apple resolves the
/// wording, then replace only its `imageProvider` with the cover already in
/// memory. Verified rendering in a real `LPLinkView` against a page serving no
/// `og:image` whatsoever — cover, title, artist, domain, all four.
final class AlbumLinkShareItem: NSObject, UIActivityItemSource, Identifiable {
    let id = UUID()
    private let url: URL
    /// Used for the Mail subject only — the card's title comes from the page.
    private let caption: String
    /// Fetched, then given the local cover. `nil` if the fetch failed, in which
    /// case the system does its own and the card falls back to `og:image`.
    private let metadata: LPLinkMetadata?

    init(url: URL, caption: String, metadata: LPLinkMetadata?) {
        self.url = url
        self.caption = caption
        self.metadata = metadata
    }

    /// `nil` for anything with no shareable link — local albums, most obviously.
    @MainActor
    static func make(for album: Album, image: UIImage?) async -> AlbumLinkShareItem? {
        guard let url = AlbumShareLink(album: album)?.url else { return nil }
        return AlbumLinkShareItem(
            url: url,
            caption: caption(for: album),
            metadata: await card(for: url, image: image)
        )
    }

    @MainActor
    static func make(for track: Track, in album: Album, image: UIImage?) async -> AlbumLinkShareItem? {
        guard let url = AlbumShareLink(track: track, in: album)?.url else { return nil }
        return AlbumLinkShareItem(
            url: url,
            caption: caption(for: track, in: album),
            metadata: await card(for: url, image: image)
        )
    }

    /// The page's own metadata, with the local cover swapped in.
    @MainActor
    private static func card(for url: URL, image: UIImage?) async -> LPLinkMetadata? {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        guard let fetched = try? await provider.startFetchingMetadata(for: url) else {
            // Offline, or the site is down. Returning nil hands the job back to
            // the system, which will retry the fetch itself — a worse card than
            // this method builds, but never a broken one.
            #if DEBUG
            print("[Link] metadata fetch failed; falling back to system preview")
            #endif
            return nil
        }
        if let image {
            fetched.imageProvider = NSItemProvider(object: image)
        }
        return fetched
    }

    /// Just the name.
    ///
    /// This is the Mail subject, not the card — the card's title comes from the
    /// page, and Messages draws the URL's *domain* under it, which no app can
    /// replace. A subject line wants the plain name, so neither of these folds
    /// in the artist even though an album's `og:title` does.
    static func caption(for track: Track, in album: Album) -> String {
        track.displayName
    }

    static func caption(for album: Album) -> String {
        album.name
    }

    // MARK: - UIActivityItemSource

    /// The placeholder decides the item's *type* before anything is resolved,
    /// so it has to be a URL — handing back a String here makes Messages treat
    /// the link as plain text and drop the card entirely.
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        caption
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        metadata
    }
}

/// Whether a shared link will actually open for the person you send it to.
@MainActor
enum ShareAccess {
    static let restrictedWarning =
        "This album has restricted access, so the link will only work for accounts added to the access list."

    /// True when the folder carries no "anyone with the link" permission, so
    /// the link resolves only for people added by name.
    ///
    /// A failed lookup answers `false`. We genuinely don't know at that point,
    /// and a warning that appears every time the network is flaky would train
    /// people to dismiss the one time it matters.
    static func isRestricted(_ album: Album, driveService: any CloudDriveService) async -> Bool {
        guard !album.isLocal else { return false }
        guard let permissions = try? await driveService.listPermissions(fileId: album.googleFolderId)
        else { return false }
        return !permissions.contains { $0.type == "anyone" }
    }
}


/// Shown while a share link is being prepared.
///
/// Preparing one is two round trips — the folder's permissions, then the page's
/// own metadata (which is what resolves the card's wording) — so there is a real
/// gap between the tap and the share sheet. Without this the button looks dead
/// and people tap it again.
struct PreparingLinkOverlay: View {
    var body: some View {
        ZStack {
            // Also swallows taps, so the button can't be fired twice.
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                LoadingIndicator()
                Text("Preparing link…")
                    .font(.uiSubheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .transition(.opacity)
    }
}
