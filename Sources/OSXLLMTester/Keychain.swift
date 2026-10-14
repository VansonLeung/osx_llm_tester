import Foundation
import Security

protocol CredentialStore {
    func save(_ value: String, for id: UUID) throws
    func read(for id: UUID) throws -> String
    func remove(for id: UUID) throws
}

struct KeychainError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
        return "Could not \(operation) the API key in Keychain: \(detail)"
    }
}

struct KeychainStore: CredentialStore {
    private static let service = "com.osxllmtester.api-keys"

    private func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id.uuidString
        ]
    }

    func save(_ value: String, for id: UUID) throws {
        guard !value.isEmpty else { try remove(for: id); return }
        let query = query(for: id)
        let update = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let attributes = query.merging(update) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(operation: "save", status: status) }
    }

    func read(for id: UUID) throws -> String {
        let query = query(for: id).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw KeychainError(operation: "read", status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(operation: "read", status: errSecDecode)
        }
        return value
    }

    func remove(for id: UUID) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "remove", status: status)
        }
    }
}
