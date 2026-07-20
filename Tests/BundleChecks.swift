// BundleCodec 검증 (PRD §3.14 — export/import 번들, 암호화, 병합).
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/EnvParser.swift \
//       env-pilot/Services/SecretStore.swift env-pilot/Services/VariableService.swift \
//       env-pilot/Services/ImportService.swift env-pilot/Services/BundleCodec.swift \
//       Tests/BundleChecks.swift -o /tmp/bundle-check && /tmp/bundle-check

import Foundation
import SwiftData

@main
struct BundleChecks {
    static func main() throws {
        // --- 원본 Workspace 구성 ---
        let source = try makeContext()
        let workspaceA = Workspace()
        source.ctx.insert(workspaceA)
        let envA = EnvEnvironment(name: "Local", sortOrder: 0)
        envA.workspace = workspaceA
        source.ctx.insert(envA)

        let repoA = Repository(name: "blog")
        repoA.gitRemoteURL = "git@github.com:me/blog.git"
        repoA.workspace = workspaceA
        source.ctx.insert(repoA)
        let targetA = Target(relativePath: ".")
        targetA.repository = repoA
        source.ctx.insert(targetA)

        try VariableService.create(key: "API_URL", value: "https://api.example.com",
                                   environmentName: "Local", target: targetA, context: source.ctx)
        try VariableService.create(key: "API_TOKEN", value: "tok_s3cret_123", isSecret: true,
                                   environmentName: "Local", target: targetA, context: source.ctx)
        let ignored = Variable(key: "LEGACY_KEY", value: "", environmentName: "Local")
        ignored.isIgnored = true
        ignored.target = targetA
        source.ctx.insert(ignored)

        // --- Payload: Secret 포함/미포함 ---
        let payloadNoSecrets = BundleCodec.makePayload(repos: [repoA], environments: ["Local"], includeSecrets: false)
        let noSecretVars = payloadNoSecrets.repositories[0].targets[0].variables
        assert(noSecretVars.first { $0.key == "API_TOKEN" }?.value == "", "Secret 미포함 시 빈 값")

        let payload = BundleCodec.makePayload(repos: [repoA], environments: ["Local"], includeSecrets: true)
        assert(payload.repositories[0].targets[0].variables.first { $0.key == "API_TOKEN" }?.value
               == "tok_s3cret_123", "Secret 포함 시 Keychain 실값")
        assert(payload.repositories[0].targets[0].variables.first { $0.key == "LEGACY_KEY" }?.isIgnored == true,
               "무시 마커 포함")

        // --- 평문 인코딩 라운드트립 ---
        let plainData = try BundleCodec.encode(payloadNoSecrets, passphrase: nil)
        let decodedPlain = try BundleCodec.decode(plainData)
        assert(decodedPlain.needsPassphrase == false && decodedPlain.payload == payloadNoSecrets, "평문 라운드트립")

        // --- 암호화: 평문 노출 없음 + 잘못된 패스프레이즈 실패 (§3.14 수용 기준) ---
        let encrypted = try BundleCodec.encode(payload, passphrase: "correct horse")
        let encryptedText = String(data: encrypted, encoding: .utf8)!
        assert(!encryptedText.contains("tok_s3cret_123"), "암호화 파일에 Secret 평문 없음")
        assert(!encryptedText.contains("api.example.com"), "암호화 파일에 일반 값도 없음")
        let decodedEncrypted = try BundleCodec.decode(encrypted)
        assert(decodedEncrypted.needsPassphrase, "암호화 번들 감지")
        let decrypted = try BundleCodec.decrypt(encrypted, passphrase: "correct horse")
        assert(decrypted == payload, "복호화 라운드트립")
        do {
            _ = try BundleCodec.decrypt(encrypted, passphrase: "wrong")
            assert(false, "잘못된 패스프레이즈는 실패해야 함")
        } catch {
            assert(error is BundleCodec.BundleError, "명확한 에러 타입")
        }
        do {
            _ = try BundleCodec.decode(Data("not json".utf8))
            assert(false, "잘못된 파일은 실패해야 함")
        } catch {}

        // --- 빈 Workspace로 import → Generate 동일성 (§3.14 수용 기준) ---
        let dest = try makeContext()
        let workspaceB = Workspace()
        dest.ctx.insert(workspaceB)

        let items = BundleCodec.plan(payload: payload, workspace: workspaceB)
        assert(items.allSatisfy { $0.kind == .add }, "빈 Workspace는 전부 add")
        assert(!items.contains { $0.key == "LEGACY_KEY" }, "무시 마커는 플랜에 미노출")
        try BundleCodec.execute(payload: payload, useFileValue: [], workspace: workspaceB, context: dest.ctx)

        let repoB = (workspaceB.repositories ?? []).first!
        assert(repoB.uuid == repoA.uuid, "Repository uuid 유지 (Keychain 계정 키 안정성)")
        assert((workspaceB.environments ?? []).map(\.name) == ["Local"], "Environment 보충")
        let targetB = (repoB.targets ?? []).first!
        assert((targetB.variables ?? []).first { $0.key == "LEGACY_KEY" }?.isIgnored == true, "무시 마커 이식")
        let secretB = (targetB.variables ?? []).first { $0.key == "API_TOKEN" }!
        assert(secretB.isSecret && secretB.value.isEmpty, "import된 Secret도 SwiftData에는 평문 없음")

        func generated(_ target: Target, _ env: String) -> String {
            let vars = (target.variables ?? []).filter { $0.environmentName == env && !$0.isIgnored }
            return EnvParser.serialize(Dictionary(uniqueKeysWithValues: vars.map {
                ($0.key, VariableService.value(of: $0))
            }))
        }
        assert(generated(targetA, "Local") == generated(targetB, "Local"),
               "export → import → Generate 결과 동일")

        // --- 재import: 충돌 정책 (§3.12 동일) ---
        try VariableService.updateValue(
            (targetB.variables ?? []).first { $0.key == "API_URL" }!, to: "https://changed.example.com",
            context: dest.ctx)
        let items2 = BundleCodec.plan(payload: payload, workspace: workspaceB)
        func kind(_ key: String) -> ImportService.Item.Kind? { items2.first { $0.key == key }?.kind }
        assert(kind("API_URL") == .conflict(existing: "https://changed.example.com"), "값 다름 → 충돌")
        assert(kind("API_TOKEN") == .same, "값 동일 → 스킵")

        // 기존 값 유지 (useFileValue 비움)
        try BundleCodec.execute(payload: payload, useFileValue: [], workspace: workspaceB, context: dest.ctx)
        let urlVar = (targetB.variables ?? []).first { $0.key == "API_URL" }!
        assert(urlVar.value == "https://changed.example.com", "기존 값 유지")
        // 파일 값 사용
        let conflictID = items2.first { $0.key == "API_URL" }!.id
        try BundleCodec.execute(payload: payload, useFileValue: [conflictID], workspace: workspaceB, context: dest.ctx)
        assert(urlVar.value == "https://api.example.com", "파일 값으로 갱신")

        // Secret 미포함 번들 재import가 기존 Secret을 지우지 않는지
        let items3 = BundleCodec.plan(payload: payloadNoSecrets, workspace: workspaceB)
        assert(items3.first { $0.key == "API_TOKEN" }?.kind == .same, "빈 Secret은 기존 값 보호 → 스킵")

        // Keychain 정리 (targetB의 Secret은 같은 uuid → 같은 계정 키라 함께 정리됨)
        for variable in (targetA.variables ?? []) where variable.isSecret {
            try VariableService.delete(variable, context: source.ctx)
        }
        print("✅ BundleCodec: all checks passed")
    }

    static func makeContext() throws -> (container: ModelContainer, ctx: ModelContext) {
        let container = try ModelContainer(
            for: Schema([Workspace.self, HistoryEntry.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return (container, ModelContext(container))
    }
}
