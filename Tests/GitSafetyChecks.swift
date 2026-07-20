// GitSafetyService 검증 (PRD §3.11).
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/GitInfo.swift \
//       env-pilot/Services/GitSafetyService.swift Tests/GitSafetyChecks.swift -o /tmp/safety-check && /tmp/safety-check

import Foundation

@main
struct GitSafetyChecks {
    static func main() throws {
        // 간이 gitignore 매칭
        func ignored(_ path: String, _ patterns: [String]) -> Bool {
            GitSafetyService.isIgnored(relativePath: path, patterns: patterns.map { (base: "", pattern: $0) })
        }
        assert(ignored(".env.local", [".env.local"]), "정확한 파일명")
        assert(ignored("apps/shop/.env.local", [".env.local"]), "파일명 패턴은 모든 레벨 매칭")
        assert(ignored(".env.local", ["*.local"]), "와일드카드")
        assert(ignored(".env.production", [".env*"]), "접두 와일드카드")
        assert(ignored("apps/shop/.env.local", ["**/.env.local"]), "**/ 접두")
        assert(ignored("apps/shop/.env", ["apps/shop/.env"]), "경로 패턴")
        assert(ignored("apps/shop/.env", ["/apps/shop/.env"]), "선행 / 경로 패턴")
        assert(!ignored(".env.local", ["node_modules/"]), "디렉토리 패턴은 파일에 미적용")
        assert(!ignored(".env.local", [".env"]), "다른 파일명은 미매칭")
        assert(!ignored(".env.local", []), "패턴 없으면 미매칭")

        // Report 통합 검사 — 실제 폴더 구조로
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("safety-check-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "ref: refs/heads/main\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        // .env.tracked 경로가 들어있는 가짜 index
        try Data("DIRC....env.tracked....".utf8).write(to: root.appendingPathComponent(".git/index"))
        try ".env.local\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "A=1\n".write(to: root.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(".env.local").path)

        let repo = Repository(name: "demo")
        let safeTarget = Target(relativePath: ".")                 // .env.local — ignored + 0600 → OK
        safeTarget.repository = repo
        let riskyTarget = Target(relativePath: ".")
        riskyTarget.outputPath = ".env.tracked"                    // ignore 안 됨 + tracked → 이슈
        repo.targets = [safeTarget, riskyTarget]

        let reports = GitSafetyService.check(repo: repo, rootURL: root)
        let safe = reports.first { $0.outputRelativePath == ".env.local" }!
        assert(safe.isIgnored && !safe.isTracked && safe.permissionsOK == true && !safe.hasIssue,
               "안전한 출력 파일 (got \(safe))")
        let risky = reports.first { $0.outputRelativePath == ".env.tracked" }!
        assert(!risky.isIgnored && risky.isTracked && risky.hasIssue, "위험한 출력 파일 (got \(risky))")

        // .gitignore에 추가 → 재검사 통과 (§3.11 수용 기준)
        try GitSafetyService.addToGitignore(line: ".env.tracked", rootURL: root)
        let recheck = GitSafetyService.check(repo: repo, rootURL: root)
            .first { $0.outputRelativePath == ".env.tracked" }!
        assert(recheck.isIgnored, "추가 후 재검사 통과")

        print("✅ GitSafetyService: all checks passed")
    }
}
