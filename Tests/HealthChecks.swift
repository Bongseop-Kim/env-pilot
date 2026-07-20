// HealthService 검증 (PRD §3.8 판정 규칙).
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/EnvParser.swift \
//       env-pilot/Services/SecretStore.swift env-pilot/Services/VariableService.swift \
//       env-pilot/Services/ExampleDiffService.swift env-pilot/Services/HealthService.swift \
//       Tests/HealthChecks.swift -o /tmp/health-check && /tmp/health-check

import Foundation
import SwiftData

@main
struct HealthChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("health-check-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "DATABASE_URL=\nAPI_KEY=\nIGNORED_KEY=\n".write(
            to: root.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)

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

        // 무시 마커 — 판정에서 제외되어야 함 (§3.8 "무시 키 제외")
        let marker = Variable(key: "IGNORED_KEY", value: "", environmentName: "Local")
        marker.isIgnored = true
        marker.target = target
        ctx.insert(marker)

        // Local: 모든 키 값 있음 → 🟢 / Development: 빈 값 → 🟡
        // Staging: 키 누락 → 🟡 / Production: 변수 없음 → 🔴
        try VariableService.create(key: "DATABASE_URL", value: "x", environmentName: "Local", target: target, context: ctx)
        try VariableService.create(key: "API_KEY", value: "y", environmentName: "Local", target: target, context: ctx)
        try VariableService.create(key: "DATABASE_URL", value: "", environmentName: "Development", target: target, context: ctx)
        try VariableService.create(key: "API_KEY", value: "y", environmentName: "Development", target: target, context: ctx)
        try VariableService.create(key: "DATABASE_URL", value: "x", environmentName: "Staging", target: target, context: ctx)

        let envs = ["Local", "Development", "Staging", "Production"]
        let items = HealthService.check(repo: repo, rootURL: root, environmentNames: envs)
        assert(items.count == 4, "env 4개 판정 (got \(items.count))")

        func status(_ env: String) -> HealthStatus? { items.first { $0.environmentName == env }?.status }
        assert(status("Local") == .healthy, "🟢 Local (got \(String(describing: status("Local"))))")
        assert(status("Development") == .warning, "🟡 빈 값 (got \(String(describing: status("Development"))))")
        assert(status("Staging") == .warning, "🟡 누락 (got \(String(describing: status("Staging"))))")
        assert(status("Production") == .critical, "🔴 변수 없음 (got \(String(describing: status("Production"))))")

        assert(items.first { $0.environmentName == "Staging" }?.missingKeys == ["API_KEY"], "누락 키 목록")
        assert(items.first { $0.environmentName == "Development" }?.emptyValueKeys == ["DATABASE_URL"], "빈 값 키 목록")
        assert(!items.contains { $0.missingKeys.contains("IGNORED_KEY") }, "무시 키는 판정 제외")
        assert(HealthService.overall(items) == .critical, "Repository 상태 = 최악 값")

        print("✅ HealthService: all checks passed")
    }
}
