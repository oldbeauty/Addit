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

        // Libraries are parallel, so restore BOTH providers' sessions —
        // each library's in-use account stays live regardless of which
        // library is being viewed. Google's restore re-registers its user
        // (which re-pins the active account as a side effect), so snapshot
        // the last-viewed account first and re-pin after.
        let lastActive = accountManager.activeAccountEmail

        if let msEmail = accountManager.activeEmail(for: .microsoft),
           let account = accountManager.accounts.first(where: { $0.email == msEmail }) {
            microsoft.restore(email: account.email, name: account.name)
        }
        // Always attempt Google's own cached session — also covers fresh
        // installs / pre-account-manager state. No-ops if none exists.
        await google.restorePreviousSignIn()

        if let lastActive, accountManager.accounts.contains(where: { $0.email == lastActive }) {
            accountManager.setActiveAccount(email: lastActive)
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
    /// existing accounts. The newly added account becomes active. The other
    /// provider's session is left untouched — sessions coexist; libraries
    /// are parallel, not mutually exclusive.
    func addAccount(provider: AccountProvider) async {
        switch provider {
        case .google:
            await google.addAccount()
        case .microsoft:
            _ = await microsoft.signIn(promptSelectAccount: true)
        }
    }

    /// Switch to an already-registered account of either provider. Only
    /// needed for changing WHICH account backs a provider's library (e.g.
    /// google1 → google2); flipping between libraries goes through the
    /// synchronous `selectProvider` instead and never lands here.
    func switchAccount(to email: String) async {
        guard email != userEmail,
              let target = accountManager.accounts.first(where: { $0.email == email }) else { return }
        isSwitchingAccount = true
        defer { isSwitchingAccount = false }

        switch target.provider {
        case .google:
            await google.switchAccount(to: email)
        case .microsoft:
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

    /// Point the active account at `provider`'s in-use account —
    /// synchronously. This is the library flip: because both providers'
    /// sessions stay live in parallel, viewing a different cloud library
    /// is pure state (no auth call, no spinner, no async gap). Returns
    /// false when no account of that provider exists at all, in which case
    /// the caller should offer sign-in. In the rare case where the
    /// provider's session doesn't match its in-use account (revoked, etc.)
    /// this falls back to a full async switch, which may prompt.
    @discardableResult
    func selectProvider(_ provider: AccountProvider) -> Bool {
        guard let email = accountManager.activeEmail(for: provider)
                ?? accountManager.accounts.first(where: { $0.provider == provider })?.email else {
            return false
        }
        let sessionEmail = provider == .google ? google.userEmail : microsoft.userEmail
        if sessionEmail?.lowercased() == email.lowercased() {
            accountManager.setActiveAccount(email: email)
        } else {
            Task { await switchAccount(to: email) }
        }
        return true
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
