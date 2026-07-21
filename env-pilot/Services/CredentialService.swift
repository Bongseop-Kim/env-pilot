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
        try context.save()
    }

    static func delete(_ credential: Credential, context: ModelContext) throws {
        SecretStore.delete(account: account(for: credential))
        context.delete(credential)
        try context.save()
    }

    /// urlString을 열 수 있는 URL로. 스키마가 없으면 https:// 를 붙인다.
    static func openableURL(_ urlString: String?) -> URL? {
        guard let raw = urlString?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        return URL(string: withScheme)
    }
}
