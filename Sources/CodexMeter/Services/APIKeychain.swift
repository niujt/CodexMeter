import Foundation
import Security

struct APIKeychain: Sendable {
    private let service = "com.codexmeter.CodexMeter.openai-billing"
    private let account = "organization-admin-key"

    static func isValid(_ key: String) -> Bool {
        key.hasPrefix("sk-") && key.count >= 16 && key.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func extract(from text: String) throws -> String {
        let tokens = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        // Accept a plain key or one environment-style assignment, never guess among multiple keys.
        let normalized = tokens.map { token in
            String(token.split(separator: "=", maxSplits: 1).last ?? Substring(token))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.filter(isValid)
        guard normalized.count == 1 else { throw APIBillingError.invalidKey }
        return normalized[0]
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw APIBillingError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), Self.isValid(key) else {
            throw APIBillingError.invalidKey
        }
        return key
    }

    func save(_ key: String) throws {
        guard Self.isValid(key) else { throw APIBillingError.invalidKey }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw APIBillingError.keychain(added) }
        } else if status != errSecSuccess { throw APIBillingError.keychain(status) }
    }
}
