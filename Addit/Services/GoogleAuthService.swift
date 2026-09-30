import Foundation
import GoogleSignIn

@Observable
final class GoogleAuthService {
    var isSignedIn = false
    var isRestoringSession = true
    var isSwitchingAccount = false
    var userName: String?
    var userEmail: String?
    /// Last interactive sign-in failure, for the sign-in screen to show. `nil`
    /// after a success or a user cancel.
    var signInError: String?
    /// A Google account whose Drive Addit can't reach. Non-nil puts the
    /// Drive-access card (`DriveAccessPrompt.swift`) over whatever is on screen.
    ///
    /// Both reasons end in the same place otherwise: a library whose albums
    /// are all on the phone, with every request behind them refused — nothing
    /// plays and no cover loads, and nothing on screen says why. "Use local"
    /// makes it worse, since it opens the library with no session at all.
    var driveAccessRequest: DriveAccessRequest?

    struct DriveAccessRequest: Identifiable, Equatable {
        enum Reason {
            /// Signed in with the Drive box unticked. Google's consent screen
            /// lists Drive as its own checkbox, off, and the sign-in succeeds
            /// whether or not it gets ticked — so a session without Drive is
            /// never adopted (see `adopt(_:)`), and this is left instead.
            case unticked
            /// An account with a library here and no session behind it. Mostly
            /// Google refusing the saved one (`invalid_grant`): access revoked,
            /// or a refresh token that ran out — every one issued while the
            /// OAuth app was in Testing lasted seven days. Also a phone restored
            /// from a backup, which brings the accounts list but not the
            /// keychain, and a second Google account left behind when the one
            /// the SDK was holding is removed — it only ever keeps one.
            case signedOut
        }
        let email: String
        let reason: Reason
        /// The reason is part of it: signing back in with the box unticked is a
        /// new question, not the old card.
        var id: String { "\(email)|\(reason)" }
    }

    @ObservationIgnored
    var accountManager = AccountManager()

    @ObservationIgnored
    private var currentUser: GIDGoogleUser? {
        didSet {
            isSignedIn = currentUser != nil
            userName = currentUser?.profile?.name
            userEmail = currentUser?.profile?.email
        }
    }

    func restorePreviousSignIn() async {
        isRestoringSession = true
        defer { isRestoringSession = false }
        do {
            let user = try await restoreSavedSession()
            // A saved session without Drive is someone who signed in with the
            // box unticked. This used to put Google's sheet straight up at
            // launch, unexplained, over the splash; now it asks first.
            if adopt(user) {
                registerCurrentUser()
            }
        } catch {
            currentUser = nil
            // Only for an account with a library here: someone who never
            // signed into Google fails this same call. And never for being
            // offline, which fails it too.
            if Self.isLostSession(error), let email = accountManager.activeGoogleEmail {
                driveAccessRequest = DriveAccessRequest(email: email, reason: .signedOut)
            }
        }
    }

    /// Returns whether a session was actually established — a cancel and a
    /// failure both read as `false`, so a caller can decline to act on a
    /// sign-in that never happened.
    @discardableResult
    func signIn() async -> Bool {
        signInError = nil
        guard let presenter = topViewController() else {
            signInError = "Couldn't find a window to present sign-in from. Try again."
            return false
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: [Constants.driveScope]
            )
            guard adopt(result.user) else { return false }
            registerCurrentUser()
            return true
        } catch {
            #if DEBUG
            print("Google Sign-In error: \(error)")
            #endif
            // Deliberately surfaced rather than swallowed. This used to fail
            // silently, dropping the user back on the sign-in screen with no
            // hint as to why — and a first attempt failing while the second
            // succeeds is exactly the shape that leaves people tapping twice
            // out of habit. A cancel isn't an error and says nothing.
            if !Self.isCancellation(error) {
                signInError = error.localizedDescription
            }
            return false
        }
    }

    /// `GIDSignIn.restorePreviousSignIn()`, except that not reaching Google
    /// isn't being signed out.
    ///
    /// The SDK's restore refreshes the access token first whenever the saved
    /// one is within ten minutes of expiry — and they only last an hour — so
    /// most launches need the network, and offline that refresh failed the
    /// whole restore. A Google user opening the app on a plane got the sign-in
    /// screen, locked out of the very albums they'd downloaded for it. The
    /// saved session was fine; it just couldn't be refreshed yet. So on a
    /// network failure it's taken as it is, and `validAccessToken()` refreshes
    /// it the first time a request needs it once there's a connection — which
    /// is also where a session that turns out to be dead raises the card.
    private func restoreSavedSession() async throws -> GIDGoogleUser {
        do {
            return try await GIDSignIn.sharedInstance.restorePreviousSignIn()
        } catch let error where Self.isUnreachable(error) {
            guard let user = Self.restoreWithoutRefresh() else { throw error }
            return user
        }
    }

    /// The SDK's own restore-without-refresh, which it keeps in a private
    /// header (`GIDSignIn_Private.h`). Reached by selector and checked for
    /// first, so an SDK update that drops it falls back to the old behaviour
    /// — signed out while offline — rather than crashing.
    private static func restoreWithoutRefresh() -> GIDGoogleUser? {
        let sdk = GIDSignIn.sharedInstance
        let selector = NSSelectorFromString("restorePreviousSignInNoRefresh")
        guard sdk.responds(to: selector) else { return nil }
        typealias Restore = @convention(c) (AnyObject, Selector) -> ObjCBool
        let restore = unsafeBitCast(sdk.method(for: selector), to: Restore.self)
        return restore(sdk, selector).boolValue ? sdk.currentUser : nil
    }

    /// Couldn't reach Google. AppAuth wraps every connection failure of a
    /// token request as `OIDGeneralErrorDomain` / `OIDErrorCodeNetworkError`.
    private static func isUnreachable(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == "org.openid.appauth.general" && error.code == -5)
            || error.domain == NSURLErrorDomain
    }

    /// A session that is gone, rather than one that couldn't be reached:
    /// Google refusing the refresh token — AppAuth's `OIDOAuthTokenErrorDomain`
    /// / `OIDErrorCodeOAuthInvalidGrant`, spelled out because AppAuth isn't
    /// imported here — or nothing saved at all. Kept this narrow on purpose:
    /// being offline fails the same refresh, and must never read as signed out.
    private static func isLostSession(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == "org.openid.appauth.oauth_token" { return error.code == -10 }
        return error.domain == kGIDSignInErrorDomain
            && error.code == GIDSignInError.hasNoAuthInKeychain.rawValue
    }

    /// Dismissing the Google sheet throws like any other failure. Reporting it
    /// as one would put an alert on screen every time someone changes their
    /// mind.
    private static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == kGIDSignInErrorDomain
            && error.code == GIDSignInError.canceled.rawValue
    }

    /// Add a new account without losing existing account data. Returns
    /// whether one was actually added; see `signIn()`.
    @discardableResult
    func addAccount() async -> Bool {
        guard let presenter = topViewController() else { return false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: [Constants.driveScope]
            )
            guard adopt(result.user) else { return false }
            registerCurrentUser()
            return true
        } catch {
            // User cancelled — nothing changed, current account stays as-is
            return false
        }
    }

    /// Switch to a different already-known account.
    func switchAccount(to email: String) async {
        guard email != userEmail else { return }
        isSwitchingAccount = true
        defer { isSwitchingAccount = false }

        // Try a silent restore FIRST, before signing anything out. The GID
        // SDK persists one session; when it's already the target account
        // this restores with no prompt. (Deliberately no signOut() here;
        // signing out first would guarantee the restore below could never
        // succeed and force re-auth every time.)
        do {
            let user = try await restoreSavedSession()
            if user.profile?.email.lowercased() == email.lowercased() {
                // Without Drive this leaves the request up and the previous
                // account in place — the card is the way on from here.
                if adopt(user) {
                    accountManager.setActiveAccount(email: email)
                }
                return
            }
        } catch {
            // No restorable session, or it errored — fall through to interactive.
        }

        // The SDK's persisted session is a different Google account (or
        // none). The SDK can't silently mint a different account's token,
        // so an interactive sign-in is unavoidable. `accountManager` is
        // only updated on success, so a cancel here leaves the previously
        // active account untouched (no desync).
        guard let presenter = topViewController() else { return }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: email,
                additionalScopes: [Constants.driveScope]
            )
            guard adopt(result.user) else { return }
            if let resultEmail = result.user.profile?.email {
                accountManager.setActiveAccount(email: resultEmail)
            }
        } catch {
            #if DEBUG
            print("Switch account error: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Drive access

    enum DriveAccessOutcome: Equatable {
        case granted
        /// Google's screen came and went and the box was still unticked.
        case stillMissing
        case cancelled
        case failed(String)
    }

    /// The only door into a session. A user whose sign-in didn't grant Drive
    /// is left un-adopted and becomes `driveAccessRequest` instead, so every
    /// route in — first sign-in, another account, a switch, a relaunch —
    /// either lands in a working library or on the card that explains why
    /// it didn't.
    private func adopt(_ user: GIDGoogleUser) -> Bool {
        guard user.grantedScopes?.contains(Constants.driveScope) == true else {
            driveAccessRequest = DriveAccessRequest(email: user.profile?.email ?? "", reason: .unticked)
            return false
        }
        driveAccessRequest = nil
        currentUser = user
        return true
    }

    /// Back to Google, for the card's button.
    ///
    /// A missed box asks for Drive alone, on the account that already signed
    /// in: no account chooser, and Google's screen is about that one
    /// permission rather than the full sign-in it was lost in the first time.
    /// The SDK only allows that on the session it's holding. Anything else —
    /// a lost session, whose tokens are no good to build on, or a
    /// relaunch that lost the half-finished one — goes round the whole sign-in
    /// again with the address filled in.
    func grantDriveAccess() async -> DriveAccessOutcome {
        guard let request = driveAccessRequest else { return .granted }
        guard let presenter = topViewController() else {
            return .failed("Couldn't find a window to present sign-in from. Try again.")
        }
        let pending = request.reason == .unticked ? GIDSignIn.sharedInstance.currentUser : nil
        do {
            let user: GIDGoogleUser
            if let pending, pending.profile?.email.lowercased() == request.email.lowercased() {
                user = try await pending.addScopes([Constants.driveScope], presenting: presenter).user
            } else {
                user = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: presenter,
                    hint: request.email,
                    additionalScopes: [Constants.driveScope]
                ).user
            }
            // The SDK reports success either way, so this is the real answer.
            guard adopt(user) else { return .stillMissing }
            registerCurrentUser()
            return .granted
        } catch {
            // Drive already on the session: nothing to ask Google, just take it.
            let nsError = error as NSError
            if nsError.domain == kGIDSignInErrorDomain,
               nsError.code == GIDSignInError.scopesAlreadyGranted.rawValue,
               let pending, adopt(pending) {
                registerCurrentUser()
                return .granted
            }
            if Self.isCancellation(error) { return .cancelled }
            #if DEBUG
            print("Google Drive access error: \(error)")
            #endif
            return .failed(error.localizedDescription)
        }
    }

    /// "Not now".
    ///
    /// For an account with a library here, the saved session is left alone,
    /// so the next launch asks again: that library doesn't work until this is
    /// answered, and a card is better than finding out from a dead play
    /// button. A first sign-in abandoned half-way is signed out instead, so
    /// someone who went back to local listening isn't asked on every launch —
    /// the Google button is right there when they want it. Never touches a
    /// session that's in use, only one that never got adopted.
    func dismissDriveAccessRequest() {
        guard let request = driveAccessRequest else { return }
        driveAccessRequest = nil
        let hasLibrary = accountManager.accounts.contains {
            $0.provider == .google && $0.email.lowercased() == request.email.lowercased()
        }
        if !hasLibrary, let pending = GIDSignIn.sharedInstance.currentUser, pending !== currentUser {
            GIDSignIn.sharedInstance.signOut()
        }
    }

    /// Sign out and remove a specific account
    func removeAccount(email: String) {
        if email == userEmail {
            GIDSignIn.sharedInstance.signOut()
            currentUser = nil
        }
        if driveAccessRequest?.email.lowercased() == email.lowercased() {
            driveAccessRequest = nil
        }
        accountManager.removeAccount(email: email)
    }

    /// Full sign-out — clears the GID SDK's persisted session. Use only
    /// when removing an account; a subsequent sign-in requires re-auth.
    /// (There is deliberately no "soft deactivate": provider sessions
    /// coexist — this session stays live even while the OneDrive library
    /// is being viewed, so cross-library playback keeps working.)
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        currentUser = nil
        driveAccessRequest = nil
    }

    func validAccessToken() async throws -> String {
        guard let user = currentUser else {
            throw AuthError.notSignedIn
        }
        // Invariant: only vend a token for the account that is this
        // PROVIDER's in-use account. Compared per-provider (not against
        // the single "active account") because libraries are parallel —
        // a Google track must be playable/syncable while the OneDrive
        // library is being viewed. Any desync (a stale session vending
        // for the wrong Google account) surfaces as a clear caught error
        // instead of silently hitting the wrong account's Drive and
        // returning a confusing 403. `activeGoogleEmail == nil` only
        // during the synchronous window of the very first sign-in
        // (before `registerCurrentUser`), so we skip the check then.
        if let activeEmail = accountManager.activeGoogleEmail,
           let currentEmail = user.profile?.email,
           activeEmail.lowercased() != currentEmail.lowercased() {
            #if DEBUG
            print("[Auth] Blocked token vend: currentUser=\(currentEmail) but in-use Google account=\(activeEmail)")
            #endif
            throw AuthError.accountMismatch
        }
        if let expiration = user.accessToken.expirationDate, expiration < Date() {
            do {
                try await user.refreshTokensIfNeeded()
            } catch {
                // The session died while the app was open — the same state a
                // relaunch would find, so the same card.
                if Self.isLostSession(error), let email = user.profile?.email {
                    currentUser = nil
                    driveAccessRequest = DriveAccessRequest(email: email, reason: .signedOut)
                }
                // Offline, AppAuth's wrapper is what reaches the screen — the
                // token URL and an error number. The connection error inside
                // it says "offline" in words, and it's what OneDrive's calls
                // already throw.
                if Self.isUnreachable(error),
                   let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
                    throw underlying
                }
                throw error
            }
        }
        return user.accessToken.tokenString
    }

    private func registerCurrentUser() {
        guard let email = currentUser?.profile?.email,
              let name = currentUser?.profile?.name else { return }
        let photoURL = currentUser?.profile?.imageURL(withDimension: 120)
        accountManager.addAccount(email: email, name: name, photoURL: photoURL)
    }

    private func topViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }),
              var top = window.rootViewController else {
            return nil
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

enum AuthError: LocalizedError {
    case notSignedIn
    case tokenRefreshFailed
    case accountMismatch

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to Google"
        case .tokenRefreshFailed: return "Failed to refresh access token"
        case .accountMismatch: return "Signed-in account doesn't match the active account"
        }
    }
}
