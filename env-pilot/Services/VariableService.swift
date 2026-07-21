import Foundation
import SwiftData
import CryptoKit

/// Variable CRUD (PRD §3.3). 유니크 제약(§2.2)과 History 기록(§3.10)을 여기서 강제한다.
enum VariableService {

    enum VariableError: LocalizedError {
        case duplicateKey(String)
        case invalidKey(String)

        var errorDescription: String? {
            switch self {
            case .duplicateKey(let key): "이미 존재하는 키입니다: \(key)"
            case .invalidKey(let key): "잘못된 키 이름입니다: \(key) (허용: 영문, 숫자, _, 숫자로 시작 불가)"
            }
        }
    }

    @discardableResult
    static func create(key: String, value: String, note: String? = nil, isSecret: Bool = false,
                       environmentName: String, target: Target, context: ModelContext) throws -> Variable {
        guard EnvParser.isValidKey(key) else { throw VariableError.invalidKey(key) }
        let duplicate = (target.variables ?? []).contains {
            $0.key == key && $0.environmentName == environmentName
        }
        guard !duplicate else { throw VariableError.duplicateKey(key) }

        let variable = Variable(key: key, value: isSecret ? "" : value, environmentName: environmentName)
        variable.note = note
        variable.isSecret = isSecret
        variable.target = target
        context.insert(variable)
        if isSecret {
            try SecretStore.save(value, account: account(for: variable))
        }
        record("created", variable, oldValue: nil, context: context)
        try context.save()
        return variable
    }

    /// Secret이면 Keychain에서, 아니면 SwiftData에서 실값을 읽는다.
    static func value(of variable: Variable) -> String {
        valueIfAvailable(of: variable) ?? ""
    }

    /// 자동 파일 쓰기는 아직 동기화되지 않은 Secret을 빈 값과 구분해야 한다.
    static func valueIfAvailable(of variable: Variable) -> String? {
        variable.isSecret ? SecretStore.read(account: account(for: variable)) : variable.value
    }

    static func updateValue(_ variable: Variable, to newValue: String, context: ModelContext) throws {
        let old = value(of: variable)
        guard old != newValue else { return }
        if variable.isSecret {
            try SecretStore.save(newValue, account: account(for: variable))
        } else {
            variable.value = newValue
        }
        variable.updatedAt = Date()
        record("updated", variable, oldValue: old, context: context)
        try context.save()
    }

    static func updateNote(_ variable: Variable, to note: String?, context: ModelContext) throws {
        variable.note = (note?.isEmpty == true) ? nil : note
        try context.save()
    }

    /// Secret 토글: 켜면 값이 Keychain으로 이동, 끄면 SwiftData로 복귀 (§3.3).
    static func setSecret(_ variable: Variable, _ isSecret: Bool, context: ModelContext) throws {
        guard variable.isSecret != isSecret else { return }
        let current = value(of: variable)
        if isSecret {
            try SecretStore.save(current, account: account(for: variable))
            variable.value = ""
        } else {
            variable.value = current
            SecretStore.delete(account: account(for: variable))
        }
        variable.isSecret = isSecret
        variable.updatedAt = Date()
        try context.save()
    }

    static func delete(_ variable: Variable, context: ModelContext, saveChanges: Bool = true) throws {
        let old = value(of: variable)
        if variable.isSecret {
            SecretStore.delete(account: account(for: variable))
        }
        record("deleted", variable, oldValue: old, context: context)
        context.delete(variable)
        if saveChanges { try context.save() }
    }

    private static func account(for variable: Variable) -> String {
        SecretStore.account(
            repoUUID: variable.target?.repository?.uuid ?? "-",
            targetPath: variable.target?.relativePath ?? "-",
            environmentName: variable.environmentName,
            key: variable.key
        )
    }

    /// §3.10: 값 자체는 저장하지 않고 SHA256 앞 8자만.
    private static func record(_ action: String, _ variable: Variable, oldValue: String?, context: ModelContext) {
        let hash = oldValue.map { old in
            String(SHA256.hash(data: Data(old.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
        }
        context.insert(HistoryEntry(
            action: action,
            key: variable.key,
            environmentName: variable.environmentName,
            repositoryName: variable.target?.repository?.name ?? "",
            targetPath: variable.target?.envFilePath ?? "",
            oldValueHash: hash
        ))
    }
}
