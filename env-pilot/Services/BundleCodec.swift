import Foundation
import SwiftData
import CryptoKit
import CommonCrypto
import Security

/// .envide 번들 export/import (PRD §3.14).
/// 단일 JSON 파일. Secret 실값 포함 시 패스프레이즈 필수 — PBKDF2(SHA256)로 키 유도 후 AES-GCM 암호화.
enum BundleCodec {

    // MARK: - 포맷

    struct Payload: Codable, Equatable {
        var environments: [String] = []
        var repositories: [Repo] = []

        struct Repo: Codable, Equatable {
            var uuid = ""
            var name = ""
            var gitRemoteURL: String?
            var defaultBranch: String?
            var localPathDisplay: String?
            var targets: [Tgt] = []
        }
        struct Tgt: Codable, Equatable {
            var relativePath = "."
            var examplePath = ".env.example"
            var outputPath = ".env.local"
            var exampleSnapshot: String?
            var variables: [Var] = []
        }
        struct Var: Codable, Equatable {
            var key = ""
            var value = ""
            var note: String?
            var isSecret = false
            var isIgnored = false
            var environmentName = ""
        }
    }

    private struct File: Codable {
        var format = "envide.bundle"
        var version = 1
        var payload: Payload?          // 평문
        var encryption: Encryption?    // Secret 포함 시
        struct Encryption: Codable {
            var salt: Data
            var iterations: Int
            var sealed: Data           // AES.GCM combined (nonce + ciphertext + tag)
        }
    }

    enum BundleError: LocalizedError {
        case invalidFormat
        case unsupportedVersion(Int)
        case wrongPassphrase

        var errorDescription: String? {
            switch self {
            case .invalidFormat: ".envide 파일 형식이 아닙니다"
            case .unsupportedVersion(let v): "지원하지 않는 번들 버전입니다: \(v)"
            case .wrongPassphrase: "패스프레이즈가 올바르지 않습니다"
            }
        }
    }

    // MARK: - Export

    /// includeSecrets면 Keychain 실값 포함 (호출부에서 패스프레이즈 암호화 필수), 아니면 Secret은 빈 값으로 구조만.
    static func makePayload(repos: [Repository], environments: [String], includeSecrets: Bool) -> Payload {
        Payload(
            environments: environments,
            repositories: repos.map { repo in
                Payload.Repo(
                    uuid: repo.uuid,
                    name: repo.name,
                    gitRemoteURL: repo.gitRemoteURL,
                    defaultBranch: repo.defaultBranch,
                    localPathDisplay: repo.localPathDisplay,
                    targets: (repo.targets ?? []).sorted { $0.relativePath < $1.relativePath }.map { target in
                        Payload.Tgt(
                            relativePath: target.relativePath,
                            examplePath: target.examplePath,
                            outputPath: target.outputPath,
                            exampleSnapshot: target.exampleSnapshot,
                            variables: (target.variables ?? []).sorted { $0.key < $1.key }.map { variable in
                                Payload.Var(
                                    key: variable.key,
                                    value: variable.isSecret && !includeSecrets
                                        ? "" : VariableService.value(of: variable),
                                    note: variable.note,
                                    isSecret: variable.isSecret,
                                    isIgnored: variable.isIgnored,
                                    environmentName: variable.environmentName)
                            })
                    })
            })
    }

    /// passphrase가 있으면 payload 전체를 AES-GCM으로 암호화해 담는다.
    static func encode(_ payload: Payload, passphrase: String?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var file = File()
        if let passphrase {
            var salt = Data(count: 16)
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            let iterations = 210_000  // OWASP 권고 (PBKDF2-HMAC-SHA256)
            let key = deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
            let sealed = try AES.GCM.seal(try encoder.encode(payload), using: key)
            file.encryption = File.Encryption(salt: salt, iterations: iterations, sealed: sealed.combined!)
        } else {
            file.payload = payload
        }
        return try encoder.encode(file)
    }

    // MARK: - Import

    /// 파일 판독. 암호화 번들이면 payload nil + needsPassphrase true — decrypt로 진행.
    static func decode(_ data: Data) throws -> (payload: Payload?, needsPassphrase: Bool) {
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              file.format == "envide.bundle" else { throw BundleError.invalidFormat }
        guard file.version == 1 else { throw BundleError.unsupportedVersion(file.version) }
        if file.encryption != nil { return (nil, true) }
        guard let payload = file.payload else { throw BundleError.invalidFormat }
        return (payload, false)
    }

    /// 잘못된 패스프레이즈는 AES-GCM 태그 검증 실패 → 명확한 에러 (부분 임포트 없음, §3.14).
    static func decrypt(_ data: Data, passphrase: String) throws -> Payload {
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              let encryption = file.encryption else { throw BundleError.invalidFormat }
        let key = deriveKey(passphrase: passphrase, salt: encryption.salt, iterations: encryption.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: encryption.sealed),
              let plain = try? AES.GCM.open(box, using: key) else { throw BundleError.wrongPassphrase }
        return try JSONDecoder().decode(Payload.self, from: plain)
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        var key = Data(count: 32)
        let password = Array(passphrase.utf8)
        key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphrase, password.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
            }
        }
        return SymmetricKey(data: key)
    }

    // MARK: - 병합 (§3.12와 동일한 충돌 정책)

    struct MergeItem: Identifiable {
        let group: String       // "repo / target / environment" — UI 그룹 라벨
        let key: String
        let newValue: String
        let kind: ImportService.Item.Kind
        var id: String { "\(group)#\(key)" }
    }

    /// 미리보기용 병합 플랜. 무시 마커(isIgnored)는 목록에 노출하지 않고 execute에서 조용히 반영.
    static func plan(payload: Payload, workspace: Workspace) -> [MergeItem] {
        var items: [MergeItem] = []
        for repoData in payload.repositories {
            let repo = findRepo(repoData, in: workspace)
            for targetData in repoData.targets {
                let target = (repo?.targets ?? []).first { $0.relativePath == targetData.relativePath }
                for varData in targetData.variables where !varData.isIgnored {
                    let group = "\(repoData.name) / \(targetData.relativePath) / \(varData.environmentName)"
                    let existing = (target?.variables ?? []).first {
                        $0.key == varData.key && $0.environmentName == varData.environmentName && !$0.isIgnored
                    }
                    let kind: ImportService.Item.Kind
                    if let existing {
                        let existingValue = VariableService.value(of: existing)
                        if varData.isSecret && varData.value.isEmpty {
                            kind = .same  // Secret 미포함 export — 기존 값 보호
                        } else {
                            kind = existingValue == varData.value ? .same : .conflict(existing: existingValue)
                        }
                    } else {
                        kind = .add
                    }
                    items.append(MergeItem(group: group, key: varData.key, newValue: varData.value, kind: kind))
                }
            }
        }
        return items
    }

    /// useFileValue: conflict 항목 중 "파일 값 사용"을 선택한 MergeItem.id 집합.
    /// 없는 Environment/Repository/Target은 생성한다 (새 Repository는 경로 미연결 상태 → §3.1 재연결 UI).
    static func execute(payload: Payload, useFileValue: Set<String>,
                        workspace: Workspace, context: ModelContext) throws {
        // Environment 보충
        let existingEnvs = Set((workspace.environments ?? []).map(\.name))
        var nextOrder = ((workspace.environments ?? []).map(\.sortOrder).max() ?? -1) + 1
        for name in payload.environments where !existingEnvs.contains(name) {
            let env = EnvEnvironment(name: name, sortOrder: nextOrder)
            env.workspace = workspace
            context.insert(env)
            nextOrder += 1
        }

        for repoData in payload.repositories {
            let repo: Repository
            if let found = findRepo(repoData, in: workspace) {
                repo = found
            } else {
                repo = Repository(name: repoData.name)
                repo.uuid = repoData.uuid  // Keychain 계정 키 안정성 — 원본과 동일 uuid 유지
                repo.gitRemoteURL = repoData.gitRemoteURL
                repo.defaultBranch = repoData.defaultBranch
                repo.localPathDisplay = repoData.localPathDisplay
                repo.workspace = workspace
                context.insert(repo)
            }

            for targetData in repoData.targets {
                let target: Target
                if let found = (repo.targets ?? []).first(where: { $0.relativePath == targetData.relativePath }) {
                    target = found
                } else {
                    target = Target(relativePath: targetData.relativePath)
                    target.examplePath = targetData.examplePath
                    target.outputPath = targetData.outputPath
                    target.exampleSnapshot = targetData.exampleSnapshot
                    target.repository = repo
                    context.insert(target)
                }

                for varData in targetData.variables {
                    let group = "\(repoData.name) / \(targetData.relativePath) / \(varData.environmentName)"
                    let itemID = "\(group)#\(varData.key)"
                    let existing = (target.variables ?? []).first {
                        $0.key == varData.key && $0.environmentName == varData.environmentName
                    }
                    if varData.isIgnored {
                        if existing == nil {  // 무시 마커 이식 — diff 재등장 방지 (§3.7)
                            let marker = Variable(key: varData.key, value: "", environmentName: varData.environmentName)
                            marker.isIgnored = true
                            marker.target = target
                            context.insert(marker)
                        }
                        continue
                    }
                    if let existing {
                        if existing.isIgnored {
                            existing.isIgnored = false  // §3.12와 동일: 무시 마커 되살림
                            try VariableService.updateValue(existing, to: varData.value, context: context)
                        } else if useFileValue.contains(itemID),
                                  !(varData.isSecret && varData.value.isEmpty),
                                  VariableService.value(of: existing) != varData.value {
                            try VariableService.updateValue(existing, to: varData.value, context: context)
                        }
                    } else {
                        try VariableService.create(
                            key: varData.key, value: varData.value, note: varData.note,
                            isSecret: varData.isSecret, environmentName: varData.environmentName,
                            target: target, context: context)
                    }
                }
            }
        }
        try context.save()
    }

    /// uuid 우선, 없으면 git remote로 기존 Repository 매칭.
    private static func findRepo(_ repoData: Payload.Repo, in workspace: Workspace) -> Repository? {
        let repos = workspace.repositories ?? []
        return repos.first { $0.uuid == repoData.uuid }
            ?? repos.first { $0.gitRemoteURL != nil && $0.gitRemoteURL == repoData.gitRemoteURL }
    }
}
