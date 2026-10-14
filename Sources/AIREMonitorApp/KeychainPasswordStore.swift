import HPCCore
import Foundation
import Security

/// The university password in the login Keychain (generic password,
/// service "AIREMonitor.AIREPassword", kept from the single-cluster release
/// so existing items are still found).
///
/// Every call is a synchronous Security framework round trip that can block
/// for as long as a SecurityAgent prompt stays open, so the app only calls
/// these off the main actor (AppModel resolves passwords in a detached
/// task).
///
/// Why macOS may ask "Leeds HPC Monitor wants to use your confidential
/// information": the items are legacy file-keychain items whose access list
/// trusts the creating app's designated requirement. A locally built bundle
/// that is only ad-hoc signed has a designated requirement equal to its
/// cdhash, which changes on every rebuild, so the first read after each
/// rebuild prompts. "Always Allow" lasts until the next rebuild. Signing the
/// bundle with a stable identity (scripts/build_bundle.sh honours
/// HPC_CODESIGN_IDENTITY) keeps the requirement — and the grant — stable.
/// Denying the prompt is reported as `.accessDenied`, never as "no saved
/// password".
enum KeychainPasswordStore {
    private static let service = "AIREMonitor.AIREPassword"

    /// `.success(nil)` only when no item exists; a denied or cancelled
    /// access prompt is `.failure(.accessDenied)`.
    static func load(account: String) -> Result<String?, KeychainError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                return .failure(.undecodable)
            }
            return .success(password)
        case errSecItemNotFound:
            return .success(nil)
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .failure(.accessDenied(status))
        default:
            return .failure(.status(status))
        }
    }

    static func save(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Include the accessibility class on update too, so items created
        // before this policy existed converge on every save.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// Existence only (no data returned), which never triggers the access
    /// prompt — so it can say "saved" while a read would still be denied.
    static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }
}

enum KeychainError: LocalizedError, Equatable {
    /// The user denied or cancelled the access prompt, or the Keychain is
    /// locked and cannot ask.
    case accessDenied(OSStatus)
    /// The item exists but its data is not UTF-8 text.
    case undecodable
    case status(OSStatus)

    init(status: OSStatus) {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            self = .accessDenied(status)
        default:
            self = .status(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Keychain access was denied."
        case .undecodable:
            return "The saved Keychain item could not be read as text."
        case .status(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain operation failed with status \(status)\(detail.map { " (\($0))" } ?? "")."
        }
    }
}

/// The credential store AppModel uses: the Keychain in the app, a fake in
/// tests (which must never touch the user's real Keychain).
protocol CredentialStore: Sendable {
    func password(for account: String) -> Result<String?, KeychainError>
    func save(_ password: String, for account: String) throws
    func delete(account: String) throws
    func exists(account: String) -> Bool
}

struct KeychainCredentialStore: CredentialStore {
    func password(for account: String) -> Result<String?, KeychainError> {
        KeychainPasswordStore.load(account: account)
    }

    func save(_ password: String, for account: String) throws {
        try KeychainPasswordStore.save(password, account: account)
    }

    func delete(account: String) throws {
        try KeychainPasswordStore.delete(account: account)
    }

    func exists(account: String) -> Bool {
        KeychainPasswordStore.exists(account: account)
    }
}
