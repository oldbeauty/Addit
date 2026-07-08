import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Microsoft-account authentication for OneDrive, mirroring the surface of
/// `GoogleAuthService` so the auth coordinator can dispatch to either
/// provider interchangeably.
///
/// Deliberately hand-rolled OAuth 2.0 + PKCE over `ASWebAuthenticationSession`
/// instead of the MSAL SDK: MSAL mandates a `msauth.<bundleId>://auth`
/// redirect URI, which would require registering every contributor's
/// per-developer bundle ID in Azure (see Local.xcconfig setup). A fixed
/// custom scheme (`Constants.microsoftAuthRedirectURI`) serves all
/// contributors from a single Azure app registration, needs no keychain
/// sharing entitlement, and adds zero SPM dependencies.
///
/// Refresh tokens are stored per-account-email in the Keychain; access
/// tokens live only in memory and are refreshed on demand via
/// `validAccessToken()` — the same contract `GoogleDriveService` relies on
/// from `GoogleAuthService.validAccessToken()`.
@Observable
final class MicrosoftAuthService: NSObject {
    var isSignedIn = false
    var userName: String?
    var userEmail: String?

    /// Shared account registry — assigned at app wiring time so Google and
    /// Microsoft accounts live in the same switcher list.
    @ObservationIgnored var accountManager: AccountManager?

    /// In-memory access tokens per account email.
    @ObservationIgnored private var tokenCache: [String: (token: String, expiry: Date)] = [:]
    @ObservationIgnored private var activeSession: ASWebAuthenticationSession?

    // MARK: - Sign-in flows

    /// Interactive sign-in (first account or adding another). On success
    /// the account is registered with the shared AccountManager and made
    /// active. Throws on network/protocol errors; user-cancel returns nil
    /// quietly.
    @discardableResult
    func signIn(promptSelectAccount: Bool = false) async -> String? {
        do {
            let verifier = Self.randomURLSafeString(bytes: 64)
            let challenge = Self.codeChallenge(for: verifier)

            var components = URLComponents(string: "\(Constants.microsoftAuthorityBase)/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: Constants.microsoftClientID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: Constants.microsoftAuthRedirectURI),
                URLQueryItem(name: "scope", value: Constants.microsoftScopes),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            if promptSelectAccount {
                components.queryItems?.append(URLQueryItem(name: "prompt", value: "select_account"))
            }

            guard let authURL = components.url else { return nil }

            let callbackURL: URL
            do {
                callbackURL = try await presentAuthSession(url: authURL)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                return nil  // user dismissed the sheet — not an error
            }

            guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
                #if DEBUG
                print("[MSAuth] Callback missing authorization code: \(callbackURL)")
                #endif
                return nil
            }

            let tokens = try await exchangeToken(body: [
                "client_id": Constants.microsoftClientID,
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Constants.microsoftAuthRedirectURI,
                "code_verifier": verifier,
                "scope": Constants.microsoftScopes,
            ])

            // Resolve the account's identity from Graph /me.
            let profile = try await fetchProfile(accessToken: tokens.accessToken)

            MSKeychain.setRefreshToken(tokens.refreshToken, for: profile.email)
            tokenCache[profile.email] = (tokens.accessToken, tokens.expiry)

            userEmail = profile.email
            userName = profile.name
            isSignedIn = true
            accountManager?.addAccount(
                email: profile.email,
                name: profile.name,
                photoURL: nil,   // Graph photo needs a separate authenticated fetch; skip for now
                provider: .microsoft
            )
            return profile.email
        } catch {
            #if DEBUG
            print("[MSAuth] Sign-in error: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    /// Silent session restore for a previously signed-in Microsoft account.
    /// Cheap: only checks that a refresh token exists in the Keychain.
    /// Actual token validity is established lazily on the first
    /// `validAccessToken()` call; if the refresh token was revoked the
    /// first API call fails and the UI can prompt a re-auth.
    func restore(email: String, name: String?) {
        guard MSKeychain.refreshToken(for: email) != nil else {
            isSignedIn = false
            return
        }
        userEmail = email
        userName = name
        isSignedIn = true
    }

    /// Activate a different already-registered Microsoft account.
    func switchTo(email: String, name: String?) -> Bool {
        guard MSKeychain.refreshToken(for: email) != nil else { return false }
        userEmail = email
        userName = name
        isSignedIn = true
        return true
    }

    func deactivate() {
        isSignedIn = false
        userEmail = nil
        userName = nil
    }

    func removeAccount(email: String) {
        MSKeychain.deleteRefreshToken(for: email)
        tokenCache[email] = nil
        if userEmail == email {
            deactivate()
        }
    }

    // MARK: - Token vending

    enum MSAuthError: LocalizedError {
        case notSignedIn
        case tokenRefreshFailed
        case accountMismatch

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Not signed in to a Microsoft account"
            case .tokenRefreshFailed: return "Failed to refresh Microsoft access token"
            case .accountMismatch: return "Signed-in account doesn't match the active account"
            }
        }
    }

    /// Returns a currently-valid access token for the active account,
    /// refreshing via the stored refresh token when needed. Mirrors
    /// `GoogleAuthService.validAccessToken()`.
    func validAccessToken() async throws -> String {
        guard let email = userEmail else { throw MSAuthError.notSignedIn }

        // Same invariant as GoogleAuthService: only vend a token when this
        // service's session matches the active account. Guards against
        // vending a Microsoft token while a different (e.g. Google)
        // account is active. Skipped when no active account is resolved
        // yet (first sign-in's synchronous window).
        if let activeEmail = accountManager?.activeAccountEmail,
           activeEmail.lowercased() != email.lowercased() {
            #if DEBUG
            print("[MSAuth] Blocked token vend: session=\(email) but active account=\(activeEmail)")
            #endif
            throw MSAuthError.accountMismatch
        }

        if let cached = tokenCache[email], cached.expiry > Date().addingTimeInterval(60) {
            return cached.token
        }

        guard let refreshToken = MSKeychain.refreshToken(for: email) else {
            throw MSAuthError.notSignedIn
        }

        do {
            let tokens = try await exchangeToken(body: [
                "client_id": Constants.microsoftClientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "scope": Constants.microsoftScopes,
            ])
            // Microsoft rotates refresh tokens on use — persist the new one.
            MSKeychain.setRefreshToken(tokens.refreshToken, for: email)
            tokenCache[email] = (tokens.accessToken, tokens.expiry)
            return tokens.accessToken
        } catch {
            #if DEBUG
            print("[MSAuth] Token refresh failed: \(error.localizedDescription)")
            #endif
            throw MSAuthError.tokenRefreshFailed
        }
    }

    // MARK: - OAuth plumbing

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private struct Tokens {
        let accessToken: String
        let refreshToken: String
        let expiry: Date
    }

    private func exchangeToken(body: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "\(Constants.microsoftAuthorityBase)/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            #if DEBUG
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            print("[MSAuth] Token endpoint error: \(bodyText)")
            #endif
            throw MSAuthError.tokenRefreshFailed
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refresh = decoded.refresh_token else {
            // offline_access scope should always yield one; treat absence as failure
            throw MSAuthError.tokenRefreshFailed
        }
        return Tokens(
            accessToken: decoded.access_token,
            refreshToken: refresh,
            expiry: Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        )
    }

    private struct Profile {
        let email: String
        let name: String
    }

    private func fetchProfile(accessToken: String) async throws -> Profile {
        var request = URLRequest(url: URL(string: "\(Constants.graphAPIBase)/me")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)

        struct Me: Decodable {
            let displayName: String?
            let userPrincipalName: String?
            let mail: String?
        }
        let me = try JSONDecoder().decode(Me.self, from: data)
        // Consumer accounts report the sign-in email as userPrincipalName;
        // `mail` is often nil for personal accounts.
        guard let email = me.mail ?? me.userPrincipalName else {
            throw MSAuthError.tokenRefreshFailed
        }
        return Profile(email: email, name: me.displayName ?? email)
    }

    private func presentAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Constants.microsoftAuthRedirectScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: MSAuthError.tokenRefreshFailed)
                }
            }
            session.presentationContextProvider = self
            // Persist cookies so switching between Microsoft accounts
            // doesn't force a full credential re-entry every time.
            session.prefersEphemeralWebBrowserSession = false
            self.activeSession = session
            session.start()
        }
    }

    // MARK: - PKCE helpers

    private static func randomURLSafeString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

extension MicrosoftAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first {
            return window
        }
        // Sign-in is always user-initiated from on-screen UI, so a scene
        // must exist by the time this is called.
        guard let scene = scenes.first else {
            preconditionFailure("No window scene available to present Microsoft sign-in")
        }
        return ASPresentationAnchor(windowScene: scene)
    }
}

// MARK: - Keychain storage for refresh tokens

private enum MSKeychain {
    private static func account(for email: String) -> String { "ms-refresh-\(email)" }
    private static let service = "com.addit.microsoft-auth"

    static func setRefreshToken(_ token: String, for email: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: email),
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func refreshToken(for email: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: email),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteRefreshToken(for email: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: email),
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    /// Base64url without padding (RFC 7636 requirement for PKCE values).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
