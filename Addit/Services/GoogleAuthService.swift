import Foundation
import GoogleSignIn

@Observable
final class GoogleAuthService {
    var isSignedIn = false
    var isRestoringSession = true
    var isSwitchingAccount = false
    var userName: String?
    var userEmail: String?

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
            #if DEBUG
            print("Google Sign-In error: \(error.localizedDescription)")
            #endif
        }
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

    /// Switch to a different already-known account
    func switchAccount(to email: String) async {
        guard email != userEmail else { return }
        isSwitchingAccount = true

        // Sign out current session
        GIDSignIn.sharedInstance.signOut()
        currentUser = nil

        // Set the desired account as active
        accountManager.setActiveAccount(email: email)

        // Try to restore — Google SDK may have this session cached
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            if user.profile?.email == email {
                if user.grantedScopes?.contains(Constants.driveScope) == true {
                    currentUser = user
                    isSwitchingAccount = false
                    return
                } else if let presenter = topViewController() {
                    let result = try await user.addScopes([Constants.driveScope], presenting: presenter)
                    currentUser = result.user
                    isSwitchingAccount = false
                    return
                }
            }
        } catch {
            // Restore didn't work for this account
        }

        // If restore didn't return the right account, prompt sign-in with hint
        guard let presenter = topViewController() else {
            isSwitchingAccount = false
            return
        }
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
            // Try to restore whatever was signed in before
            await restorePreviousSignIn()
        }
        isSwitchingAccount = false
    }

    /// Sign out and remove a specific account
    func removeAccount(email: String) {
        if email == userEmail {
            GIDSignIn.sharedInstance.signOut()
            currentUser = nil
        }
        accountManager.removeAccount(email: email)
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        currentUser = nil
    }

    func validAccessToken() async throws -> String {
        guard let user = currentUser else {
            throw AuthError.notSignedIn
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

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to Google"
        case .tokenRefreshFailed: return "Failed to refresh access token"
        }
    }
}
