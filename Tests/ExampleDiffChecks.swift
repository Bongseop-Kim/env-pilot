// ExampleDiffService 검증 (PRD §3.6, §3.7 수용 기준).
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/EnvParser.swift \
//       env-pilot/Services/SecretStore.swift env-pilot/Services/VariableService.swift \
//       env-pilot/Services/ExampleDiffService.swift Tests/ExampleDiffChecks.swift -o /tmp/diff-check && /tmp/diff-check

import Foundation
import SwiftData

@main
struct ExampleDiffChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("diff-check-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let exampleURL = root.appendingPathComponent(".env.example")

        let container = try ModelContainer(
            for: Schema([Workspace.self, HistoryEntry.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let ctx = ModelContext(container)
        let repo = Repository(name: "demo")
        ctx.insert(repo)
        let target = Target(relativePath: ".")
        target.outputPath = ".env"
        target.repository = repo
        ctx.insert(target)

        // 최초 스캔: 스냅샷만 저장, diff 없음 (§3.6)
        try "DATABASE_URL=\nOLD_API=\n".write(to: exampleURL, atomically: true, encoding: .utf8)
        assert(ExampleDiffService.scan(repo: repo, rootURL: root, context: ctx).isEmpty, "최초 스캔은 diff 없음")
        assert(target.exampleSnapshot != nil, "스냅샷 저장")

        // example 변경: +GEMINI_API_KEY, +SENTRY_DSN, -OLD_API (PRD §10 시나리오)
        try "DATABASE_URL=\nGEMINI_API_KEY=\nSENTRY_DSN=\n".write(to: exampleURL, atomically: true, encoding: .utf8)
        var diffs = ExampleDiffService.scan(repo: repo, rootURL: root, context: ctx)
        assert(diffs.count == 1, "diff 1개 target")
        assert(diffs[0].addedKeys == ["GEMINI_API_KEY", "SENTRY_DSN"], "추가 키 (got \(diffs[0].addedKeys))")
        assert(diffs[0].removedKeys == ["OLD_API"], "삭제 키 (got \(diffs[0].removedKeys))")

        // 추가 처리 → 해당 실제 파일에 빈 값 생성, 재스캔 시 diff에서 사라짐 (§3.7)
        try ExampleDiffService.resolveAdded(key: "GEMINI_API_KEY", action: .addToFile,
                                            target: target, context: ctx)
        let created = (target.variables ?? []).filter { $0.key == "GEMINI_API_KEY" }
        assert(created.count == 1 && created[0].environmentName == ".env"
               && created[0].value.isEmpty && !created[0].isIgnored, "해당 파일에 빈 값 생성")

        // 무시 처리 → isIgnored 마커, 재스캔 시 diff에서 사라짐
        try ExampleDiffService.resolveAdded(key: "SENTRY_DSN", action: .ignore,
                                            target: target, context: ctx)
        let markers = (target.variables ?? []).filter { $0.key == "SENTRY_DSN" }
        assert(markers.count == 1 && markers[0].isIgnored, "무시 마커")

        // 삭제 처리 → 변수 제거 (여기선 원래 변수가 없었으므로 스냅샷만 정리)
        try ExampleDiffService.resolveRemoved(key: "OLD_API", action: .deleteFromFile,
                                              target: target, context: ctx)

        diffs = ExampleDiffService.scan(repo: repo, rootURL: root, context: ctx)
        assert(diffs.isEmpty, "처리 완료 후 재스캔 시 같은 diff가 다시 나타나지 않음 (got \(diffs))")

        // 무시한 키는 example에 계속 있어도 diff에 안 뜸 (§3.7 수용 기준) — 위 재스캔이 증명.
        // 삭제 액션이 실제 변수를 지우는지도 확인
        try VariableService.create(key: "TO_DELETE", value: "x", environmentName: target.envFilePath,
                                   target: target, context: ctx)
        try ExampleDiffService.resolveRemoved(key: "TO_DELETE", action: .deleteFromFile,
                                              target: target, context: ctx)
        assert(!(target.variables ?? []).contains { $0.key == "TO_DELETE" }, "삭제 액션이 변수 제거")

        print("✅ ExampleDiffService: all checks passed")
    }
}
