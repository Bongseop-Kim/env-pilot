import Foundation
import Security

/// Secret 값의 Keychain 저장 (PRD §2.2).
/// ponytail: 로그인 키체인 generic password — adhoc 서명에서도 동작.
/// Phase 4에서 kSecUseDataProtectionKeychain + kSecAttrSynchronizable로 이전해 iCloud Keychain 동기화.
enum SecretStore {
    private static let service = "com.duegosystem.env-pilot"

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Keychain 오류 (\(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    /// PRD §2.2 계정 키 규칙. repoUUID는 기기 간 동일한 값이어야 한다.
    static func account(repoUUID: String, targetPath: String, environmentName: String, key: String) -> String {
        "envide.\(repoUUID).\(targetPath).\(environmentName).\(key)"
    }

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
