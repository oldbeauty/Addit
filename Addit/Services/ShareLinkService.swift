import Foundation

/// Holds an album link between the moment iOS hands it to the app and the
/// moment there is somewhere to put the album.
///
/// The two are further apart than they look. `onOpenURL` fires on the scene, up
/// in `AdditApp`, above the `ModelContainer` — and a link tapped by someone who
/// isn't signed in yet arrives before there's even a real store to write to. So
/// the link waits here, as state, and `ContentView` drains it once an account
/// exists. That also makes the sign-in detour work for free: tap link → sign in
/// → the album opens, with nothing to re-tap.
@Observable
final class ShareLinkService {
    /// A link plus a fresh identity. The identity is the point: tapping the
    /// same link twice has to count as two requests, or a retry after a
    /// failure would be a no-op.
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let link: AlbumShareLink
    }

    private(set) var request: Request?

    /// True while the album is being fetched and written.
    var isImporting = false

    /// True while an *outgoing* link is being prepared — the folder's
    /// permissions, then the page's own metadata.
    ///
    /// The only outbound state here, and it lives on the service for a reason
    /// the inbound half doesn't have: an overlay driven by a view's own
    /// `@State` can only be drawn inside that view's bounds, and one of the
    /// share buttons belongs to the mini player, which is a bar. There the
    /// "Preparing link…" panel had nowhere to appear and the button read as
    /// dead for both round trips. `ContentView` draws it now, so it covers the
    /// window whichever button was pressed.
    ///
    /// `AccessSheet` is the exception and keeps a local flag: nothing
    /// `ContentView` draws can appear above a presented sheet.
    var isPreparingLink = false

    /// Set for anything the user needs to read — no access, wrong account,
    /// dead folder. Presented as an alert and cleared by dismissing it.
    var failure: String?

    /// Which account the user picked to receive this album, once asked.
    /// Survives the view rebuild that changing accounts causes, which is what
    /// stops the picker reappearing forever.
    private(set) var chosenAccount: String?

    /// Whether we've already asked the coordinator to change account for the
    /// current request. Guards against a switch that doesn't take leaving the
    /// handler bouncing off the same mismatch forever.
    private(set) var didAttemptAccountSwitch = false

    /// Returns false for URLs that aren't album links, which is the common
    /// case — the OAuth callbacks come through the same door.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let link = AlbumShareLink(url: url) else { return false }
        request = Request(link: link)
        chosenAccount = nil
        didAttemptAccountSwitch = false
        isImporting = false
        failure = nil
        #if DEBUG
        print("[Link] queued \(link.source.rawValue) album \(link.folderId)")
        #endif
        return true
    }

    func chooseAccount(_ email: String) {
        chosenAccount = email
        // A new destination deserves a fresh attempt at reaching it.
        didAttemptAccountSwitch = false
    }

    func markAccountSwitchAttempted() {
        didAttemptAccountSwitch = true
    }

    /// Done with this request, however it ended.
    func clear() {
        request = nil
        isImporting = false
        chosenAccount = nil
        didAttemptAccountSwitch = false
    }
}
