import Foundation
import SwiftData

/// Credential CRUD — 비밀번호는 SwiftData에 저장하지 않고 항상 Keychain(SecretStore)에만 둔다.
enum CredentialService {

    static func account(for credential: Credential) -> String {
        "envide.cred.\(credential.uuid)"
    }

    @discardableResult
    static func create(label: String, username: String, password: String,
                       urlString: String? = nil, note: String? = nil,
                       repository: Repository, context: ModelContext) throws -> Credential {
        let credential = Credential(label: label, username: username)
        credential.urlString = urlString?.isEmpty == true ? nil : urlString
        credential.note = note?.isEmpty == true ? nil : note
        credential.repository = repository
        context.insert(credential)
        try SecretStore.save(password, account: account(for: credential))
        record("created", credential, context: context)
        try context.save()
        return credential
    }

    static func password(of credential: Credential) -> String {
        SecretStore.read(account: account(for: credential)) ?? ""
    }

    static func updatePassword(_ credential: Credential, to newValue: String, context: ModelContext) throws {
        guard password(of: credential) != newValue else { return }
        try SecretStore.save(newValue, account: account(for: credential))
        credential.updatedAt = Date()
        record("updated", credential, context: context)
        try context.save()
    }

    /// 비밀번호 외 필드 일괄 수정 — Keychain 계정명은 uuid 기반이라 이동이 없다.
    static func update(_ credential: Credential, label: String, username: String,
                       urlString: String?, note: String?, context: ModelContext) throws {
        credential.label = label
        credential.username = username
        credential.urlString = urlString?.isEmpty == true ? nil : urlString
        credential.note = note?.isEmpty == true ? nil : note
        credential.updatedAt = Date()
        record("updated", credential, context: context)
        try context.save()
    }

    static func delete(_ credential: Credential, context: ModelContext) throws {
        SecretStore.delete(account: account(for: credential))
        record("deleted", credential, context: context)
        context.delete(credential)
        try context.save()
    }

    /// Accounts 변경도 History에 남긴다 — key 자리에 label, 비밀번호 값/해시는 저장하지 않음.
    private static func record(_ action: String, _ credential: Credential, context: ModelContext) {
        context.insert(HistoryEntry(
            action: action,
            key: credential.label,
            environmentName: "",
            repositoryName: credential.repository?.name ?? "",
            targetPath: "",
            source: "credential"
        ))
    }

    /// urlString을 열 수 있는 URL로. 스키마가 없으면 https:// 를 붙인다.
    static func openableURL(_ urlString: String?) -> URL? {
        guard let raw = urlString?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        return URL(string: withScheme)
    }
}
