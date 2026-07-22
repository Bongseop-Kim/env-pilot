// Credential 모델/서비스 스모크 체크.
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift Tests/CredentialChecks.swift -o /tmp/cred-check && /tmp/cred-check

import Foundation
import SwiftData

@main
struct CredentialChecks {
    static func main() throws {
        let schema = Schema([Workspace.self, HistoryEntry.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let ctx = ModelContext(container)

        let ws = Workspace()
        ctx.insert(ws)
        let repo = Repository(name: "blog")
        repo.workspace = ws
        ctx.insert(repo)
        let cred = Credential(label: "Staging 관리자", username: "admin@example.com")
        cred.urlString = "https://staging.example.com"
        cred.repository = repo
        ctx.insert(cred)
        try ctx.save()

        // 역관계 + 그래프에 Credential이 포함되는지 (schema는 Workspace에서 관계로 유도)
        assert(repo.credentials?.count == 1, "repository ← credential 역관계")
        assert(repo.credentials?.first?.label == "Staging 관리자", "필드 저장")

        // cascade: Repository 삭제 → Credential 연쇄 삭제
        ctx.delete(repo)
        try ctx.save()
        let remaining = try ctx.fetchCount(FetchDescriptor<Credential>())
        assert(remaining == 0, "cascade 삭제, 남은 credential: \(remaining)")

        print("CredentialChecks OK")
    }
}
