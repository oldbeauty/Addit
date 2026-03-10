import Foundation
import GoogleSignIn

@Observable
final class GoogleAuthService {
    var isSignedIn = false
    var userName: String?
    var userEmail: String?

    @ObservationIgnored
    private var currentUser: GIDGoogleUser? {
        didSet {
            isSignedIn = currentUser != nil
            userName = currentUser?.profile?.name
            userEmail = currentUser?.profile?.email
        }
    }

    func restorePreviousSignIn() async {
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            if user.grantedScopes?.contains(Constants.driveScope) == true {
                currentUser = user
            } else if let presenter = topViewController() {
                let result = try await user.addScopes([Constants.driveScope], presenting: presenter)
                currentUser = result.user
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
        } catch {
            print("Google Sign-In error: \(error.localizedDescription)")
        }
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
