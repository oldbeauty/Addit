import Foundation

/// Unified session facade over `GoogleAuthService` and
/// `MicrosoftAuthService`. Views talk to this instead of a concrete
/// provider service — it exposes the same member names the views used when
/// Google was the only provider (`userEmail`, `isSignedIn`,
/// `accountManager`, `switchAccount`, …) and dispatches to the right
/// provider based on the account's `provider` field.
///
/// Single source of truth for "who is active" is the shared
/// `AccountManager` (owned by GoogleAuthService, also wired into
/// MicrosoftAuthService). The coordinator's computed identity properties
/// validate that the provider service actually has a live session for the
/// active account, so a half-restored state reads as signed out rather
/// than mismatched.
@Observable
final class CloudAuthCoordinator {
    @ObservationIgnored let google: GoogleAuthService
    @ObservationIgnored let microsoft: MicrosoftAuthService

    var isRestoringSession = true
    var isSwitchingAccount = false

    init(google: GoogleAuthService, microsoft: MicrosoftAuthService) {
        self.google = google
        self.microsoft = microsoft
        // One registry for both providers.
        microsoft.accountManager = google.accountManager
    }

    var accountManager: AccountManager { google.accountManager }

    var activeAccount: Account? { accountManager.activeAccount }

    var activeProvider: AccountProvider { activeAccount?.provider ?? .google }

    var userEmail: String? {
        guard let account = activeAccount else { return nil }
        switch account.provider {
        case .google:
            return google.userEmail == account.email ? account.email : nil
        case .microsoft:
            return microsoft.userEmail == account.email ? account.email : nil
        }
    }

    var userName: String? {
        switch activeProvider {
        case .google: return google.userName
        case .microsoft: return microsoft.userName
        }
    }

    var isSignedIn: Bool { userEmail != nil }

    // MARK: - Session lifecycle

    func restorePreviousSignIn() async {
        isRestoringSession = true
        defer { isRestoringSession = false }

        guard let account = accountManager.activeAccount else {
            // No registered accounts (fresh install or pre-account-manager
            // state) — let the Google SDK try its own cached session, which
            // is exactly what the app did before OneDrive existed.
            await google.restorePreviousSignIn()
            return
        }

        switch account.provider {
        case .google:
            await google.restorePreviousSignIn()
        case .microsoft:
            microsoft.restore(email: account.email, name: account.name)
        }
    }

    /// First-time sign-in buttons on SignInView.
    func signInGoogle() async {
        await google.signIn()
    }

    func signInMicrosoft() async {
        _ = await microsoft.signIn()
    }

    /// Add another account of the given provider without dropping data for
    /// existing accounts. The newly added account becomes active.
    func addAccount(provider: AccountProvider) async {
        switch provider {
        case .google:
            microsoft.deactivate()
            await google.addAccount()
        case .microsoft:
            if await microsoft.signIn(promptSelectAccount: true) != nil {
                // MicrosoftAuthService registered + activated the account.
                // Soft-deactivate Google (keep its SDK session) so token
                // vending can't cross wires but switching back needs no
                // re-auth.
                google.deactivate()
            }
        }
    }

    /// Switch to an already-registered account of either provider.
    func switchAccount(to email: String) async {
        guard email != userEmail,
              let target = accountManager.accounts.first(where: { $0.email == email }) else { return }
        isSwitchingAccount = true
        defer { isSwitchingAccount = false }

        switch target.provider {
        case .google:
            microsoft.deactivate()
            await google.switchAccount(to: email)
        case .microsoft:
            // Soft-deactivate Google (not signOut) so switching back to it
            // later restores silently — same treatment Microsoft already
            // gets via its Keychain-backed deactivate().
            google.deactivate()
            if microsoft.switchTo(email: email, name: target.name) {
                accountManager.setActiveAccount(email: email)
            } else {
                // Keychain entry gone (e.g. revoked) — needs interactive
                // sign-in to re-establish.
                if let signedInEmail = await microsoft.signIn(promptSelectAccount: true),
                   signedInEmail == email {
                    accountManager.setActiveAccount(email: email)
                }
            }
        }
    }

    /// Remove an account and its session material. The caller (account
    /// switcher UI) is responsible for switching to another account
    /// afterwards, matching the existing Google-only flow.
    func removeAccount(email: String) {
        guard let account = accountManager.accounts.first(where: { $0.email == email }) else { return }
        switch account.provider {
        case .google:
            // Handles sign-out if active AND removes from the manager.
            google.removeAccount(email: email)
        case .microsoft:
            microsoft.removeAccount(email: email)
            accountManager.removeAccount(email: email)
        }
    }

    func signOut() {
        google.signOut()
        microsoft.deactivate()
    }
}
