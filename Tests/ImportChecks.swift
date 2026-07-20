// ImportService 검증 (PRD §3.12 충돌 정책).
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/EnvParser.swift \
//       env-pilot/Services/SecretStore.swift env-pilot/Services/VariableService.swift \
//       env-pilot/Services/ImportService.swift Tests/ImportChecks.swift -o /tmp/import-check && /tmp/import-check

import Foundation
import SwiftData

@main
struct ImportChecks {
    static func main() throws {
        let container = try ModelContainer(
            for: Schema([Workspace.self, HistoryEntry.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let ctx = ModelContext(container)
        let repo = Repository(name: "demo")
        ctx.insert(repo)
        let target = Target(relativePath: ".")
        target.repository = repo
        ctx.insert(target)

        try VariableService.create(key: "SAME", value: "v1", environmentName: "Local", target: target, context: ctx)
        try VariableService.create(key: "CONFLICT", value: "old", environmentName: "Local", target: target, context: ctx)
        let marker = Variable(key: "WAS_IGNORED", value: "", environmentName: "Local")
        marker.isIgnored = true
        marker.target = target
        ctx.insert(marker)

        let file = """
        NEW_KEY=fresh
        SAME=v1
        CONFLICT=new
        WAS_IGNORED=revived
        """
        let (items, warnings) = ImportService.plan(content: file, target: target, environmentName: "Local")
        assert(warnings.isEmpty, "경고 없음")

        func kind(_ key: String) -> ImportService.Item.Kind? { items.first { $0.key == key }?.kind }
        assert(kind("NEW_KEY") == .add, "신규 키")
        assert(kind("SAME") == .same, "동일 값 → 스킵")
        assert(kind("CONFLICT") == .conflict(existing: "old"), "충돌 감지")
        assert(kind("WAS_IGNORED") == .add, "무시 마커는 신규 취급")

        // 실행: CONFLICT는 파일 값 사용 선택
        try ImportService.execute(items: items, useFileValue: ["CONFLICT"], target: target,
                                  environmentName: "Local", context: ctx)
        func value(_ key: String) -> String? {
            (target.variables ?? []).first { $0.key == key && !$0.isIgnored }.map { VariableService.value(of: $0) }
        }
        assert(value("NEW_KEY") == "fresh", "신규 생성")
        assert(value("CONFLICT") == "new", "파일 값으로 갱신")
        assert(value("SAME") == "v1", "동일 값 유지")
        assert(value("WAS_IGNORED") == "revived" && marker.isIgnored == false, "무시 마커 되살림")

        // 기존 값 유지 선택 시
        let (items2, _) = ImportService.plan(content: "CONFLICT=another", target: target, environmentName: "Local")
        try ImportService.execute(items: items2, useFileValue: [], target: target,
                                  environmentName: "Local", context: ctx)
        assert(value("CONFLICT") == "new", "기존 값 유지 선택 시 미변경")

        print("✅ ImportService: all checks passed")
    }
}
