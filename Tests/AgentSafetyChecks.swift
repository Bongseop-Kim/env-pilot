// AI 에이전트 노출 검사 검증 (Claude Code .env deny 규칙).
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/GitInfo.swift \
//       env-pilot/Services/GitSafetyService.swift Tests/AgentSafetyChecks.swift -o /tmp/agent-check && /tmp/agent-check

import Foundation

@main
struct AgentSafetyChecks {
    static func main() throws {
        // deny 규칙 감지
        assert(!GitSafetyService.hasEnvDenyRule([:]), "빈 설정")
        assert(!GitSafetyService.hasEnvDenyRule(["permissions": ["deny": ["Bash(rm *)"]]]), ".env 무관 규칙")
        assert(GitSafetyService.hasEnvDenyRule(["permissions": ["deny": ["Read(**/.env.local)"]]]), "Read .env 규칙")
        assert(!GitSafetyService.hasEnvDenyRule(["permissions": ["deny": ["Write(.env)"]]]), "Read 아닌 규칙은 미인정")

        // 규칙 병합 — 멱등, 기존 설정 보존
        let base: [String: Any] = ["permissions": ["deny": ["Bash(rm *)"], "allow": ["Read(src/**)"]], "model": "opus"]
        let merged = GitSafetyService.insertingClaudeDenyRules(into: base, fileNames: [".env.local", ".env", ".env.local"])
        let permissions = merged["permissions"] as! [String: Any]
        let deny = permissions["deny"] as! [String]
        assert(deny == ["Bash(rm *)", "Read(**/.env)", "Read(**/.env.local)"], "기존 유지 + 정렬·중복 제거 (got \(deny))")
        assert(permissions["allow"] as! [String] == ["Read(src/**)"], "allow 보존")
        assert(merged["model"] as! String == "opus", "다른 최상위 키 보존")
        let again = GitSafetyService.insertingClaudeDenyRules(into: merged, fileNames: [".env.local"])
        assert((again["permissions"] as! [String: Any])["deny"] as! [String] == deny, "멱등")

        // 파일 통합 — 없던 파일 생성 → 상태 전이 nil → false → true
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-check-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        assert(GitSafetyService.claudeEnvDenyStatus(rootURL: root) == nil, ".claude 없음 → 해당 없음")
        try fm.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        assert(GitSafetyService.claudeEnvDenyStatus(rootURL: root) == false, ".claude 있음 + 규칙 없음 → 미차단")
        try GitSafetyService.addClaudeEnvDenyRules(fileNames: [".env.local"], rootURL: root)
        assert(GitSafetyService.claudeEnvDenyStatus(rootURL: root) == true, "규칙 추가 후 → 차단됨")

        // AGENTS.md 공통 규칙 — 파일 없음 → 생성, 기존 내용 보존, 멱등
        let agentsURL = root.appendingPathComponent("AGENTS.md")
        assert(!GitSafetyService.agentsMdEnvRuleStatus(rootURL: root), "AGENTS.md 없음 → 미설치")
        try GitSafetyService.addAgentsMdEnvRule(rootURL: root)
        assert(GitSafetyService.agentsMdEnvRuleStatus(rootURL: root), "추가 후 → 설치됨")
        let created = try String(contentsOf: agentsURL, encoding: .utf8)
        try GitSafetyService.addAgentsMdEnvRule(rootURL: root)
        let unchanged = try String(contentsOf: agentsURL, encoding: .utf8)
        assert(unchanged == created, "멱등 — 재호출 시 변화 없음")
        try "# 기존 가이드\n".write(to: agentsURL, atomically: true, encoding: .utf8)
        try GitSafetyService.addAgentsMdEnvRule(rootURL: root)
        let appended = try String(contentsOf: agentsURL, encoding: .utf8)
        assert(appended.hasPrefix("# 기존 가이드\n"), "기존 내용 보존")
        assert(appended.contains(GitSafetyService.agentsBeginMarker), "블록 추가됨")

        print("✅ AgentSafety: all checks passed")
    }
}
