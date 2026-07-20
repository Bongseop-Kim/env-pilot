// GenerateService 검증 (PRD §3.4 수용 기준).
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/EnvParser.swift \
//       env-pilot/Services/SecretStore.swift env-pilot/Services/VariableService.swift \
//       env-pilot/Services/GenerateService.swift Tests/GenerateChecks.swift -o /tmp/generate-check && /tmp/generate-check

import Foundation
import SwiftData

@main
struct GenerateChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("generate-check-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root.appendingPathComponent("apps/shop"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let container = try ModelContainer(
            for: Schema([Workspace.self, HistoryEntry.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let ctx = ModelContext(container)
        let repo = Repository(name: "demo")
        ctx.insert(repo)
        let rootTarget = Target(relativePath: ".")
        rootTarget.repository = repo
        ctx.insert(rootTarget)
        let shopTarget = Target(relativePath: "apps/shop")
        shopTarget.repository = repo
        ctx.insert(shopTarget)
        let emptyTarget = Target(relativePath: "apps/empty")   // 변수 없음 + 디렉토리 없음
        emptyTarget.repository = repo
        ctx.insert(emptyTarget)

        try VariableService.create(key: "DATABASE_URL", value: "postgres://localhost",
                                   environmentName: "Local", target: rootTarget, context: ctx)
        try VariableService.create(key: "API_KEY", value: "has space #hash",
                                   environmentName: "Local", target: rootTarget, context: ctx)
        try VariableService.create(key: "SHOP_URL", value: "https://shop.dev",
                                   environmentName: "Local", target: shopTarget, context: ctx)
        try VariableService.create(key: "PROD_ONLY", value: "x",
                                   environmentName: "Production", target: shopTarget, context: ctx)

        // 1차 생성: create 2, skipEmpty 1
        var plans = GenerateService.makePlans(repo: repo, rootURL: root, environmentName: "Local")
        assert(plans.map(\.action) == [.create, .skipEmpty, .create], "1차 플랜 (got \(plans.map(\.action)))")
        assert(GenerateService.execute(plans, rootURL: root).isEmpty, "실행 에러 없음")

        // 수용 기준: 생성된 파일을 파서로 읽으면 앱 값과 일치 (라운드트립)
        let written = try String(contentsOf: root.appendingPathComponent(".env.local"), encoding: .utf8)
        let parsed = EnvParser.parse(written)
        assert(parsed.entries.map(\.key) == ["API_KEY", "DATABASE_URL"], "키 정렬")
        assert(parsed.entries.first?.value == "has space #hash", "특수문자 값 라운드트립")

        // 권한 0600
        let perms = try fm.attributesOfItem(atPath: root.appendingPathComponent(".env.local").path)[.posixPermissions] as! NSNumber
        assert(perms.intValue == 0o600, "파일 권한 0600 (got \(String(perms.intValue, radix: 8)))")

        // 수용 기준: 내용 동일하면 파일을 건드리지 않음 (mtime 보존)
        let mtimeBefore = try fm.attributesOfItem(atPath: root.appendingPathComponent(".env.local").path)[.modificationDate] as! Date
        plans = GenerateService.makePlans(repo: repo, rootURL: root, environmentName: "Local")
        assert(plans.map(\.action) == [.unchanged, .skipEmpty, .unchanged], "재실행 플랜은 unchanged")
        _ = GenerateService.execute(plans, rootURL: root)
        let mtimeAfter = try fm.attributesOfItem(atPath: root.appendingPathComponent(".env.local").path)[.modificationDate] as! Date
        assert(mtimeBefore == mtimeAfter, "unchanged는 mtime 보존")

        // 값 변경 → overwrite + diff
        let v = (rootTarget.variables ?? []).first { $0.key == "DATABASE_URL" }!
        try VariableService.updateValue(v, to: "postgres://prod", context: ctx)
        plans = GenerateService.makePlans(repo: repo, rootURL: root, environmentName: "Local")
        let rootPlan = plans.first { $0.targetPath == "." }!
        assert(rootPlan.action == .overwrite, "값 변경 시 overwrite")
        let diff = GenerateService.lineDiff(old: rootPlan.existingContent!, new: rootPlan.content)
        assert(diff.removed == ["DATABASE_URL=postgres://localhost"], "diff removed")
        assert(diff.added == ["DATABASE_URL=postgres://prod"], "diff added")

        // Environment 격리: Production 생성 시 Local 값 미포함
        plans = GenerateService.makePlans(repo: repo, rootURL: root, environmentName: "Production")
        let shopPlan = plans.first { $0.targetPath == "apps/shop" }!
        assert(!shopPlan.content.contains("SHOP_URL") && shopPlan.content.contains("PROD_ONLY"), "환경 격리")

        print("✅ GenerateService: all checks passed")
    }
}
