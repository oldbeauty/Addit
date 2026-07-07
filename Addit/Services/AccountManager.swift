import Foundation

@Observable
final class AccountManager {
    private(set) var accounts: [Account] = []
    private(set) var activeAccountEmail: String?

    @ObservationIgnored
    private let defaults = UserDefaults.standard
    private let accountsKey = "addit_accounts"
    private let activeAccountKey = "addit_active_account"

    var activeAccount: Account? {
        accounts.first { $0.email == activeAccountEmail }
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
        guard accounts.contains(where: { $0.email == email }) else { return }
        activeAccountEmail = email
        defaults.set(email, forKey: activeAccountKey)
    }

    func removeAccount(email: String) {
        accounts.removeAll { $0.email == email }
        saveAccounts()
        if activeAccountEmail == email {
            activeAccountEmail = accounts.first?.email
            if let active = activeAccountEmail {
                defaults.set(active, forKey: activeAccountKey)
            } else {
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
