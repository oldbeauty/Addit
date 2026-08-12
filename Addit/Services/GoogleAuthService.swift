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
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            if user.grantedScopes?.contains(Constants.driveScope) == true {
                currentUser = user
                registerCurrentUser()
            } else if let presenter = topViewController() {
                let result = try await user.addScopes([Constants.driveScope], presenting: presenter)
                currentUser = result.user
                registerCurrentUser()
            }
        } catch {
            currentUser = nil
        }
    }

    func signIn() async {
        signInError = nil
        guard let presenter = topViewController() else {
            signInError = "Couldn't find a window to present sign-in from. Try again."
            return
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: [Constants.driveScope]
            )
            currentUser = result.user
            registerCurrentUser()
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
        }
    }

    /// Dismissing the Google sheet throws like any other failure. Reporting it
    /// as one would put an alert on screen every time someone changes their
    /// mind.
    private static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == kGIDSignInErrorDomain
            && error.code == GIDSignInError.canceled.rawValue
    }

    /// Add a new account without losing existing account data
    func addAccount() async {
        guard let presenter = topViewController() else { return }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: [Constants.driveScope]
            )
            currentUser = result.user
            registerCurrentUser()
        } catch {
            // User cancelled — nothing changed, current account stays as-is
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
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            if user.profile?.email.lowercased() == email.lowercased() {
                if user.grantedScopes?.contains(Constants.driveScope) == true {
                    currentUser = user
                    accountManager.setActiveAccount(email: email)
                    return
                } else if let presenter = topViewController() {
                    let result = try await user.addScopes([Constants.driveScope], presenting: presenter)
                    currentUser = result.user
                    accountManager.setActiveAccount(email: email)
                    return
                }
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
            currentUser = result.user
            if let resultEmail = result.user.profile?.email {
                accountManager.setActiveAccount(email: resultEmail)
            }
        } catch {
            #if DEBUG
            print("Switch account error: \(error.localizedDescription)")
            #endif
        }
    }

    /// Sign out and remove a specific account
    func removeAccount(email: String) {
        if email == userEmail {
            GIDSignIn.sharedInstance.signOut()
            currentUser = nil
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
            try await user.refreshTokensIfNeeded()
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
