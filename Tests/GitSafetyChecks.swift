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

        // .git/index 파싱 — 정확한 경로 매칭 (".env" ≠ ".env.example")
        func indexV2(_ paths: [String]) -> Data {
            var data = Data("DIRC".utf8)
            func u32(_ v: UInt32) { data.append(contentsOf: [
                UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
            u32(2); u32(UInt32(paths.count))
            for path in paths.sorted() {
                data.append(Data(count: 60))   // ctime..sha1 = 60바이트 (테스트에선 0)
                let name = Array(path.utf8)
                data.append(contentsOf: [UInt8(name.count >> 8), UInt8(name.count & 0xFF)])  // flags = 경로 길이
                data.append(contentsOf: name)
                let pad = (62 + name.count) % 8
                data.append(Data(count: pad == 0 ? 8 : 8 - pad))   // NUL 포함 8바이트 배수 패딩
            }
            return data
        }
        let idx = indexV2([".env.example", "apps/store/.env.example", "src/main.swift"])
        assert(!GitSafetyService.isTracked(relativePath: ".env", indexData: idx), ".env.example에 오탐 없음")
        assert(!GitSafetyService.isTracked(relativePath: "apps/store/.env", indexData: idx), "하위 경로 오탐 없음")
        assert(GitSafetyService.isTracked(relativePath: ".env.example", indexData: idx), "정확한 경로 매칭")
        assert(GitSafetyService.isTracked(relativePath: "src/main.swift", indexData: idx), "여러 엔트리 순회")
        assert(!GitSafetyService.isTracked(relativePath: "main.swift", indexData: idx), "suffix 오탐 없음")
        assert(!GitSafetyService.isTracked(relativePath: ".env", indexData: Data()), "빈/손상 index는 미추적")

        // Report 통합 검사 — 실제 폴더 구조로
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("safety-check-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "ref: refs/heads/main\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        // .env.tracked만 추적 중인 v2 index (.env.example은 오탐 검증용)
        try indexV2([".env.tracked", ".env.example"]).write(to: root.appendingPathComponent(".git/index"))
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
