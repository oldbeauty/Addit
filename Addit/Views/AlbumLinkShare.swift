import LinkPresentation
import SwiftUI
import UIKit

/// An album or song link, handed to the share sheet as a URL.
///
/// It deliberately does **not** supply `LPLinkMetadata`, and that is the whole
/// point of this type's history. Supplying it produced an instant card built
/// from the cover already in memory — but `LPLinkMetadata`'s public API has a
/// `title` and nothing else. No subtitle. So an app-supplied card can only ever
/// be one line, and handing one over *replaces* the richer metadata Messages
/// builds by fetching the page — which does carry a second line.
///
/// Spotify was the proof. Its track pages serve exactly the tags ours do:
///
///     og:title        I Never Dream
///     og:description  Against All Logic · 2012 - 2017 · Song · 2018
///
/// Nothing special, no private API — its links simply get *fetched*, so both
/// lines survive. Ours were being overridden before they could be.
///
/// The cost is the cover. Fetched cards get their art from `/cover/<id>`, which
/// reads Drive anonymously and so only resolves for albums shared "anyone with
/// the link"; a restricted album falls back to the plain tile instead of the
/// local cover this used to supply. That is the accepted trade — a restricted
/// link barely works for its recipient anyway, which is now warned about
/// before sending.
final class AlbumLinkShareItem: NSObject, UIActivityItemSource, Identifiable {
    let id = UUID()
    private let url: URL
    /// Used for the Mail subject only — the card's title comes from the page.
    private let caption: String

    init(url: URL, caption: String) {
        self.url = url
        self.caption = caption
    }

    /// `nil` for anything with no shareable link — local albums, most obviously.
    @MainActor
    static func make(for album: Album, coverId: String? = nil) -> AlbumLinkShareItem? {
        guard let url = AlbumShareLink(album: album, coverId: coverId)?.url else { return nil }
        return AlbumLinkShareItem(url: url, caption: caption(for: album))
    }

    @MainActor
    static func make(for track: Track, in album: Album, coverId: String? = nil) -> AlbumLinkShareItem? {
        guard let url = AlbumShareLink(track: track, in: album, coverId: coverId)?.url else { return nil }
        return AlbumLinkShareItem(url: url, caption: caption(for: track, in: album))
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
