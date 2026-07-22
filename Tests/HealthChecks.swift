// 실제 env 파일 단위 HealthService 검증.
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
        let root = fm.temporaryDirectory.appendingPathComponent(
            "health-check-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let container = try ModelContainer(
            for: Schema([Workspace.self, HistoryEntry.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let repo = Repository(name: "demo")
        context.insert(repo)

        func makeTarget(_ directory: String, fileName: String = ".env") throws -> Target {
            let dir = directory == "." ? root : root.appendingPathComponent(directory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "DATABASE_URL=\nAPI_KEY=\n".write(
                to: dir.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
            let target = Target(relativePath: directory)
            target.outputPath = fileName
            target.repository = repo
            context.insert(target)
            return target
        }

        let local = try makeTarget(".")
        let development = try makeTarget("apps/dev", fileName: ".env.local")
        let staging = try makeTarget("apps/staging", fileName: ".env.staging")
        _ = try makeTarget("apps/production", fileName: ".env.production")

        try "DATABASE_URL=\nAPI_KEY=\nIGNORED_KEY=\n".write(
            to: root.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
        let marker = Variable(key: "IGNORED_KEY", value: "", environmentName: local.envFilePath)
        marker.isIgnored = true
        marker.target = local
        context.insert(marker)

        // 실제 파일별로 healthy / 빈 값 / 누락 / 변수 없음을 판정한다.
        try VariableService.create(key: "DATABASE_URL", value: "x", environmentName: local.envFilePath,
                                   target: local, context: context)
        try VariableService.create(key: "API_KEY", value: "y", environmentName: local.envFilePath,
                                   target: local, context: context)
        try VariableService.create(key: "DATABASE_URL", value: "", environmentName: development.envFilePath,
                                   target: development, context: context)
        try VariableService.create(key: "API_KEY", value: "y", environmentName: development.envFilePath,
                                   target: development, context: context)
        try VariableService.create(key: "DATABASE_URL", value: "x", environmentName: staging.envFilePath,
                                   target: staging, context: context)

        let items = HealthService.check(repo: repo, rootURL: root)
        assert(items.count == 4, "실제 env 파일 4개 판정 (got \(items.count))")

        func item(_ path: String) -> HealthService.Item? { items.first { $0.filePath == path } }
        assert(item(".env")?.status == .healthy, "루트 .env healthy")
        assert(item("apps/dev/.env.local")?.status == .warning, "빈 값 warning")
        assert(item("apps/staging/.env.staging")?.status == .warning, "누락 warning")
        assert(item("apps/production/.env.production")?.status == .critical, "변수 없음 critical")
        assert(item("apps/staging/.env.staging")?.missingKeys == ["API_KEY"], "누락 키 목록")
        assert(item("apps/dev/.env.local")?.emptyValueKeys == ["DATABASE_URL"], "빈 값 키 목록")
        assert(!items.contains { $0.missingKeys.contains("IGNORED_KEY") }, "무시 키는 판정 제외")
        assert(HealthService.overall(items) == .critical, "Repository 상태 = 최악 값")

        print("✅ HealthService: all checks passed")
    }
}
