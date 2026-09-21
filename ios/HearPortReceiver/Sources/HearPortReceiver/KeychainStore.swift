#if canImport(Security) && os(iOS)
import Foundation
import Security

public struct KeychainRememberedCredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "com.hearport.receiver", account: String = "remembered") {
        self.service = service
        self.account = account
    }

    public func save(_ credential: RememberedCredential) throws {
        let record: [String: Data] = [
            "peer_id": credential.peerID,
            "pair_secret": credential.pairSecret,
            "windows_spki_sha256": credential.windowsSPKISHA256
        ]
        let payload = try PropertyListEncoder().encode(record)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    public func load() throws -> RememberedCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        let record = try PropertyListDecoder().decode([String: Data].self, from: data)
        guard let peerID = record["peer_id"],
              let pairSecret = record["pair_secret"],
              let spki = record["windows_spki_sha256"] else {
            throw PairingSecurityError.invalidLength
        }
        return try RememberedCredential(peerID: peerID, pairSecret: pairSecret, windowsSPKISHA256: spki)
    }

    public func remove() throws {
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
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}
#endif
