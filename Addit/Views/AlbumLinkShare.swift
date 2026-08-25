import LinkPresentation
import SwiftUI
import UIKit

/// An album or song link, handed to the share sheet with a preview card that
/// has both the artist line *and* the cover already on this device.
///
/// Getting both took three attempts, so the reasoning is worth keeping.
///
/// The artist line is not something an app can set: `LPLinkMetadata` exposes a
/// `title` and no subtitle. It appears because Apple, when it *fetches* a page,
/// follows `music:musician` and renders that page's `<title>` underneath. So a
/// hand-built `LPLinkMetadata` can never have one — supplying it replaces the
/// fetched card wholesale and silently costs the artist.
///
/// The cover has the opposite problem. `og:image` is read by an
/// unauthenticated fetcher, so art inside a restricted Drive folder is
/// invisible to it, and OneDrive has no anonymous thumbnail at all.
///
/// The resolution is to do both: fetch the metadata so Apple resolves the
/// artist, then replace only its `imageProvider` with the cover already in
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
    /// `LPLinkMetadata` has a `title` and nothing else — no subtitle — and the
    /// small grey line Messages draws beneath it is the URL's *domain*, which
    /// no app can replace. So there is exactly one line to write here, and
    /// folding the artist into it with a dash only produced a long single line
    /// in title font, which is not the two-line card it was imitating.
    ///
    /// The artist still travels: the page's `og:description` carries it, which
    /// is what Slack, Discord and the web card render underneath the title.
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
/// own metadata (which is what resolves the artist line) — so there is a real
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
