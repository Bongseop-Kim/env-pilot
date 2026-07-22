// GitHistoryScanService 검증 — Git 히스토리의 .env 흔적 탐지.
// 실행: swiftc -parse-as-library env-pilot/Services/GitInfo.swift \
//       env-pilot/Services/GitHistoryScanService.swift Tests/GitHistoryScanChecks.swift \
//       -o /tmp/history-check && /tmp/history-check
// 통합 검사는 실제 git CLI로 fixture 저장소를 만든다 (개발 머신 전용).

import Foundation

@main
struct GitHistoryScanChecks {
    static func main() throws {
        // 파일명 판정 — pre-commit hook 기준과 동일
        assert(GitHistoryScanService.isEnvName(".env"), ".env")
        assert(GitHistoryScanService.isEnvName(".env.local"), ".env.local")
        assert(GitHistoryScanService.isEnvName(".env.production"), ".env.production")
        assert(!GitHistoryScanService.isEnvName(".env.example"), "example 제외")
        assert(!GitHistoryScanService.isEnvName(".env.local.example"), "중첩 example 제외")
        assert(!GitHistoryScanService.isEnvName(".env.sample"), "sample 제외")
        assert(!GitHistoryScanService.isEnvName(".envrc"), ".envrc는 대상 아님")
        assert(!GitHistoryScanService.isEnvName("foo.env"), "접두 불일치")

        // tree entry 정식 파싱: "<mode> <name>\0<20바이트 sha>" 반복
        var tree = Data()
        for name in ["README.md", ".env", ".env.example"] {
            tree.append(Data("100644 \(name)\u{0}".utf8))
            tree.append(Data(repeating: 0xAB, count: 20))
        }
        var found = Set<String>()
        GitHistoryScanService.collectTreeEntries(tree[...], into: &found)
        assert(found == [".env"], "tree 파싱: \(found)")

        // delta 휴리스틱: NUL로 끝나는 tree entry 패턴만 매칭
        found = []
        var delta = Data("junk 100644 .env.local\u{0}".utf8)
        delta.append(Data(repeating: 0xCD, count: 20))
        GitHistoryScanService.collectHeuristicMatches(delta, into: &found)
        assert(found == [".env.local"], "delta 휴리스틱: \(found)")

        found = []
        GitHistoryScanService.collectHeuristicMatches(Data("문서에 .env 언급만 있는 blob".utf8), into: &found)
        assert(found.isEmpty, "NUL 없는 텍스트는 오탐하지 않음")

        // 통합: 실제 git 저장소에서 loose object와 packfile 모두 탐지
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("history-check-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        @discardableResult
        func git(_ args: [String]) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", root.path,
                           "-c", "user.email=t@t", "-c", "user.name=t",
                           "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }

        try git(["init", "-q"])
        try "SECRET=x\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "SECRET=\n".write(to: root.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "add env"])
        try git(["rm", "-q", ".env"])
        try git(["commit", "-qm", "remove env"])

        // loose object 상태에서 탐지
        var leaks = GitHistoryScanService.scan(rootURL: root)
        assert(leaks == [".env"], "loose 스캔: \(String(describing: leaks))")

        // pack 상태에서 탐지 (gc로 object 변화 → fingerprint 캐시도 무효화되어야 함)
        try git(["gc", "-q", "--aggressive", "--prune=now"])
        leaks = GitHistoryScanService.scan(rootURL: root)
        assert(leaks == [".env"], "pack 스캔: \(String(describing: leaks))")

        // .env가 커밋된 적 없는 저장소는 빈 결과
        let clean = fm.temporaryDirectory
            .appendingPathComponent("history-clean-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: clean, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: clean) }
        func gitClean(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", clean.path,
                           "-c", "user.email=t@t", "-c", "user.name=t",
                           "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        try gitClean(["init", "-q"])
        try "hi\n".write(to: clean.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try gitClean(["add", "."])
        try gitClean(["commit", "-qm", "init"])
        assert(GitHistoryScanService.scan(rootURL: clean) == [], "깨끗한 저장소")

        // Git 저장소가 아니면 nil
        assert(GitHistoryScanService.scan(rootURL: fm.temporaryDirectory) == nil, "비Git은 nil")

        print("GitHistoryScanChecks passed")
    }
}
