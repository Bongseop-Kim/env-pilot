// VariableService + SecretStore 검증 (PRD §3.3, §2.2 유니크 제약, §3.10 History).
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/EnvParser.swift \
//       env-pilot/Services/SecretStore.swift env-pilot/Services/VariableService.swift \
//       Tests/VariableChecks.swift -o /tmp/variable-check && /tmp/variable-check

import Foundation
import SwiftData

@main
struct VariableChecks {
    static func main() throws {
        let container = try ModelContainer(
            for: Schema([Workspace.self, HistoryEntry.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let ctx = ModelContext(container)
        let repo = Repository(name: "blog")
        ctx.insert(repo)
        let target = Target(relativePath: ".")
        target.repository = repo
        ctx.insert(target)

        // 생성 + 중복 거부 + 잘못된 키 거부
        try VariableService.create(key: "DATABASE_URL", value: "postgres://localhost",
                                   environmentName: "Local", target: target, context: ctx)
        assert((try? VariableService.create(key: "DATABASE_URL", value: "x",
                                            environmentName: "Local", target: target, context: ctx)) == nil,
               "같은 (target, env)에 중복 키 거부")
        try VariableService.create(key: "DATABASE_URL", value: "y",
                                   environmentName: "Production", target: target, context: ctx)  // 다른 env는 허용
        assert((try? VariableService.create(key: "1BAD", value: "x",
                                            environmentName: "Local", target: target, context: ctx)) == nil,
               "잘못된 키 이름 거부")

        // 값 수정 + History (값 대신 해시)
        let v = (target.variables ?? []).first { $0.environmentName == "Local" }!
        try VariableService.updateValue(v, to: "postgres://prod", context: ctx)
        assert(VariableService.value(of: v) == "postgres://prod", "값 수정")
        let history = try ctx.fetch(FetchDescriptor<HistoryEntry>())
        assert(history.count == 3, "created 2 + updated 1 기록 (got \(history.count))")
        let updated = history.first { $0.action == "updated" }!
        assert(updated.oldValueHash?.count == 8, "이전 값은 8자 해시로만")
        assert(!history.contains { $0.oldValueHash?.contains("postgres") == true }, "History에 실값 없음")

        // Secret 토글: Keychain 왕복 + SwiftData에서 평문 제거
        try VariableService.setSecret(v, true, context: ctx)
        assert(v.value.isEmpty, "Secret 전환 시 SwiftData 값 비움")
        assert(VariableService.value(of: v) == "postgres://prod", "Keychain에서 실값 읽기")
        try VariableService.setSecret(v, false, context: ctx)
        assert(v.value == "postgres://prod", "Secret 해제 시 SwiftData 복귀")

        // 키 이름 변경 — Secret은 Keychain 계정이 키에 묶여 있어 값 이동까지 확인
        try VariableService.setSecret(v, true, context: ctx)
        try VariableService.rename(v, to: "DB_URL", context: ctx)
        assert(v.key == "DB_URL", "키 이름 변경")
        assert(VariableService.value(of: v) == "postgres://prod", "rename 후 Keychain 값 유지")
        assert((try? VariableService.rename(v, to: "1BAD", context: ctx)) == nil, "rename 잘못된 키 거부")
        let other = try VariableService.create(key: "OTHER", value: "x",
                                               environmentName: "Local", target: target, context: ctx)
        assert((try? VariableService.rename(v, to: "OTHER", context: ctx)) == nil, "rename 중복 키 거부")
        try VariableService.delete(other, context: ctx)
        try VariableService.setSecret(v, false, context: ctx)

        // 삭제
        try VariableService.delete(v, context: ctx)
        let remaining = try ctx.fetch(FetchDescriptor<Variable>())
        assert(remaining.count == 1 && remaining.first?.environmentName == "Production", "삭제")

        print("✅ VariableService: all checks passed")
    }
}
