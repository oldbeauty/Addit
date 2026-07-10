import Foundation

@Observable
final class AccountManager {
    private(set) var accounts: [Account] = []
    private(set) var activeAccountEmail: String?

    /// The most-recently-active account for each provider, tracked
    /// independently of `activeAccountEmail`. Because the app treats
    /// Google Drive / OneDrive / Local as parallel *libraries* (not
    /// mutually-exclusive accounts), both a Google and a Microsoft
    /// account can be "in use" at once — you're viewing one provider's
    /// library while the other's session stays live in the background.
    /// These drive the "in use" checkmarks in the account switcher and
    /// tell the coordinator which account to resume when you flip to a
    /// provider's library. `activeAccountEmail` is always equal to
    /// whichever of these matches the currently-viewed cloud provider.
    private(set) var activeGoogleEmail: String?
    private(set) var activeMicrosoftEmail: String?

    @ObservationIgnored
    private let defaults = UserDefaults.standard
    private let accountsKey = "addit_accounts"
    private let activeAccountKey = "addit_active_account"
    private let activeGoogleKey = "addit_active_google"
    private let activeMicrosoftKey = "addit_active_microsoft"

    var activeAccount: Account? {
        accounts.first { $0.email == activeAccountEmail }
    }

    /// True if this account is the live/in-use account for its provider —
    /// i.e. the one that would be used if you switched to that provider's
    /// library. Used for the account switcher's checkmarks.
    func isInUse(_ account: Account) -> Bool {
        switch account.provider {
        case .google: return account.email == activeGoogleEmail
        case .microsoft: return account.email == activeMicrosoftEmail
        }
    }

    /// The in-use account email for a given provider, if any.
    func activeEmail(for provider: AccountProvider) -> String? {
        switch provider {
        case .google: return activeGoogleEmail
        case .microsoft: return activeMicrosoftEmail
        }
    }

    init() {
        loadAccounts()
    }

    func addAccount(email: String, name: String, photoURL: URL?, provider: AccountProvider = .google) {
        guard !accounts.contains(where: { $0.email == email }) else {
            // Account already exists — just switch to it
            setActiveAccount(email: email)
            return
        }
        let account = Account(email: email, name: name, photoURL: photoURL, provider: provider)
        accounts.append(account)
        saveAccounts()
        setActiveAccount(email: email)
    }

    func setActiveAccount(email: String) {
        guard let account = accounts.first(where: { $0.email == email }) else { return }
        activeAccountEmail = email
        defaults.set(email, forKey: activeAccountKey)
        // Also record it as the in-use account for its provider, so the
        // other provider's in-use account is preserved for its checkmark
        // and for silent resume when you flip to its library.
        switch account.provider {
        case .google:
            activeGoogleEmail = email
            defaults.set(email, forKey: activeGoogleKey)
        case .microsoft:
            activeMicrosoftEmail = email
            defaults.set(email, forKey: activeMicrosoftKey)
        }
    }

    func removeAccount(email: String) {
        let removed = accounts.first(where: { $0.email == email })
        accounts.removeAll { $0.email == email }
        saveAccounts()

        // Clear per-provider in-use tracking if this was that provider's
        // in-use account.
        if activeGoogleEmail == email {
            activeGoogleEmail = nil
            defaults.removeObject(forKey: activeGoogleKey)
        }
        if activeMicrosoftEmail == email {
            activeMicrosoftEmail = nil
            defaults.removeObject(forKey: activeMicrosoftKey)
        }

        if activeAccountEmail == email {
            // Fall back to any remaining account of the same provider
            // first (keeps you in the same library if possible), else any.
            let sameProvider = removed.flatMap { r in
                accounts.first(where: { $0.provider == r.provider })
            }
            let fallback = sameProvider ?? accounts.first
            if let fallback {
                setActiveAccount(email: fallback.email)
            } else {
                activeAccountEmail = nil
                defaults.removeObject(forKey: activeAccountKey)
            }
        }
    }

    func updateAccount(email: String, name: String, photoURL: URL?) {
        guard let index = accounts.firstIndex(where: { $0.email == email }) else { return }
        // Preserve the existing provider — updates only refresh profile info.
        let provider = accounts[index].provider
        accounts[index] = Account(email: email, name: name, photoURL: photoURL, provider: provider)
        saveAccounts()
    }

    /// Sanitized string safe for use in file/directory names
    static func storageIdentifier(for email: String) -> String {
        email.replacingOccurrences(of: "@", with: "_at_")
             .replacingOccurrences(of: ".", with: "_")
    }


    // MARK: - Persistence

    private func loadAccounts() {
        if let data = defaults.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = decoded
        }
        activeAccountEmail = defaults.string(forKey: activeAccountKey)
        activeGoogleEmail = defaults.string(forKey: activeGoogleKey)
        activeMicrosoftEmail = defaults.string(forKey: activeMicrosoftKey)
        // Drop any persisted pointers to accounts that no longer exist.
        if let g = activeGoogleEmail, !accounts.contains(where: { $0.email == g }) {
            activeGoogleEmail = nil
        }
        if let m = activeMicrosoftEmail, !accounts.contains(where: { $0.email == m }) {
            activeMicrosoftEmail = nil
        }
        // If active account was removed, fall back to first
        if activeAccountEmail != nil && !accounts.contains(where: { $0.email == activeAccountEmail }) {
            activeAccountEmail = accounts.first?.email
        }
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: accountsKey)
        }
    }
}

enum AccountProvider: String, Codable {
    case google
    case microsoft

    /// The storage source albums created under this account use.
    var storageSource: StorageSource {
        switch self {
        case .google: return .googleDrive
        case .microsoft: return .oneDrive
        }
    }

    var displayName: String {
        switch self {
        case .google: return "Google Drive"
        case .microsoft: return "OneDrive"
        }
    }
}

extension StorageSource {
    /// Inverse of `AccountProvider.storageSource` — the provider whose
    /// account backs this library. `nil` for local storage.
    var provider: AccountProvider? {
        switch self {
        case .googleDrive: return .google
        case .oneDrive: return .microsoft
        case .localStorage: return nil
        }
    }
}

struct Account: Codable, Identifiable, Equatable {
    let email: String
    let name: String
    let photoURL: URL?
    var provider: AccountProvider = .google

    var id: String { email }

    init(email: String, name: String, photoURL: URL?, provider: AccountProvider = .google) {
        self.email = email
        self.name = name
        self.photoURL = photoURL
        self.provider = provider
    }

    // Backward-compatible decoding: accounts persisted before the
    // provider field existed are Google accounts by definition.
    enum CodingKeys: String, CodingKey {
        case email, name, photoURL, provider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        name = try container.decode(String.self, forKey: .name)
        photoURL = try container.decodeIfPresent(URL.self, forKey: .photoURL)
        provider = try container.decodeIfPresent(AccountProvider.self, forKey: .provider) ?? .google
    }
}
