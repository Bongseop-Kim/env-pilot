import Foundation
import Security

/// Secret 값의 Keychain 저장 (PRD §2.2, §3.13).
/// 데이터 보호 키체인 + kSecAttrSynchronizable — iCloud Keychain으로 기기 간 동기화.
/// 미서명 빌드(CLI 검증 등)는 entitlement가 없어 -34018이 나므로 레거시 로그인 키체인으로 폴백.
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

    /// modern = 데이터 보호 키체인 + iCloud 동기화 / legacy = Phase 3까지의 로그인 키체인.
    private static func query(account: String, modern: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if modern {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    private static func upsert(query: [String: Any], data: Data) -> OSStatus {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = upsert(query: query(account: account, modern: true), data: data)
        if status == errSecSuccess { return }
        guard status == errSecMissingEntitlement else { throw KeychainError(status: status) }
        // ponytail: entitlement 없는 빌드 폴백 — 동기화는 안 되지만 로컬 동작은 유지
        let legacyStatus = upsert(query: query(account: account, modern: false), data: data)
        guard legacyStatus == errSecSuccess else { throw KeychainError(status: legacyStatus) }
    }

    static func read(account: String) -> String? {
        for modern in [true, false] {  // 마이그레이션 전 아이템은 레거시 위치에서 읽힘
            var query = query(account: account, modern: modern)
            query[kSecReturnData as String] = true
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account, modern: true) as CFDictionary)
        SecItemDelete(query(account: account, modern: false) as CFDictionary)
    }

    /// Phase 3까지의 로그인 키체인 아이템을 iCloud Keychain으로 1회 이전 (§3.13). 앱 시작 시 호출, 멱등.
    /// (kSecAttrSynchronizable 미지정 쿼리는 동기화 아이템을 반환하지 않으므로 이전된 아이템은 재매칭되지 않는다.)
    static func migrateLegacyItems() {
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(listQuery as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("envide."),
                  let data = item[kSecValueData as String] as? Data else { continue }
            let status = upsert(query: query(account: account, modern: true), data: data)
            guard status == errSecSuccess else { return }  // entitlement 없음 등 — 다음 실행에서 재시도
            SecItemDelete(query(account: account, modern: false) as CFDictionary)
        }
    }
}
