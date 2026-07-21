// SwiftData 모델 스모크 체크 (PRD §2.2).
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift Tests/ModelChecks.swift -o /tmp/model-check && /tmp/model-check

import Foundation
import SwiftData

@main
struct ModelChecks {
    static func main() throws {
        let schema = Schema([Workspace.self, HistoryEntry.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let ctx = ModelContext(container)

        // 전체 그래프 삽입
        let ws = Workspace()
        ctx.insert(ws)
        let repo = Repository(name: "blog")
        repo.workspace = ws
        ctx.insert(repo)
        let env = EnvEnvironment(name: "Local")
        env.repository = repo
        ctx.insert(env)
        let target = Target(relativePath: "apps/shop")
        target.repository = repo
        ctx.insert(target)
        let variable = Variable(key: "DATABASE_URL", value: "postgres://localhost", environmentName: "Local")
        variable.target = target
        ctx.insert(variable)
        ctx.insert(HistoryEntry(action: "created", key: "DATABASE_URL", environmentName: "Local",
                                repositoryName: "blog", targetPath: "apps/shop"))
        try ctx.save()

        // 관계 역방향 확인
        assert(ws.repositories?.count == 1, "workspace ← repository 역관계")
        assert(repo.targets?.first?.variables?.first?.key == "DATABASE_URL", "그래프 탐색")

        // cascade: Repository 삭제 → Target, Variable, Environment 연쇄 삭제
        ctx.delete(repo)
        try ctx.save()
        let targetCount = try ctx.fetchCount(FetchDescriptor<Target>())
        let variableCount = try ctx.fetchCount(FetchDescriptor<Variable>())
        let environmentCount = try ctx.fetchCount(FetchDescriptor<EnvEnvironment>())
        let historyCount = try ctx.fetchCount(FetchDescriptor<HistoryEntry>())
        assert(targetCount == 0, "target cascade 삭제")
        assert(variableCount == 0, "variable cascade 삭제")
        assert(environmentCount == 0, "environment cascade 삭제")
        assert(historyCount == 1, "history는 독립 보존")

        // 레거시 마이그레이션: Workspace 전역 Environment → 각 Repository로 복제 이관 (멱등)
        let repoX = Repository(name: "x")
        repoX.workspace = ws
        ctx.insert(repoX)
        let repoY = Repository(name: "y")
        repoY.workspace = ws
        ctx.insert(repoY)
        let already = EnvEnvironment(name: "Prod", sortOrder: 0)  // repoY에 이미 존재 → 중복 생성 금지
        already.repository = repoY
        ctx.insert(already)
        for (i, name) in ["Local", "Prod"].enumerated() {
            let legacy = EnvEnvironment(name: name, sortOrder: i)
            legacy.workspace = ws
            ctx.insert(legacy)
        }
        try ctx.save()

        Workspace.migrateEnvironmentsToRepositories(ctx)
        Workspace.migrateEnvironmentsToRepositories(ctx)  // 멱등 확인
        assert(repoX.environmentNames == ["Local", "Prod"], "레거시 환경이 repo로 이관")
        assert(repoY.environmentNames == ["Prod", "Local"], "기존 환경 유지 + 없는 것만 보충")
        let legacyLeft = try ctx.fetch(FetchDescriptor<EnvEnvironment>()).filter { $0.repository == nil }
        assert(legacyLeft.isEmpty, "레거시 전역 환경은 제거")

        print("✅ Models: all checks passed")
    }
}
