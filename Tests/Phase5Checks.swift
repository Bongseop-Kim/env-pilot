// Phase 5 검증 (PRD §3.16–§3.21): CopyFormat, example 역생성, drift, pre-commit hook.
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/EnvParser.swift \
//       env-pilot/Services/GitInfo.swift env-pilot/Services/SecretStore.swift \
//       env-pilot/Services/VariableService.swift env-pilot/Services/GenerateService.swift \
//       env-pilot/Services/ExampleDiffService.swift env-pilot/Services/GitSafetyService.swift \
//       env-pilot/Services/ClipboardService.swift Tests/Phase5Checks.swift -o /tmp/phase5-check && /tmp/phase5-check

import Foundation

@main
struct Phase5Checks {
    static func main() throws {
        try checkCopyFormats()
        try checkExampleContent()
        try checkDrift()
        try checkHookBlockEditing()
        try checkHookFileOps()
        try checkHookBlocksRealCommit()
        print("✅ Phase5: all checks passed")
    }

    // §3.20 — Copy as 포맷
    static func checkCopyFormats() throws {
        let values = ["B_KEY": "plain", "A_KEY": "has \"quote\" and $VAR and `tick` and \\slash"]

        let shell = CopyFormat.shell.render(values)
        assert(shell == """
            export A_KEY="has \\"quote\\" and \\$VAR and \\`tick\\` and \\\\slash"
            export B_KEY="plain"

            """, "shell exports 이스케이프/정렬 (got \(shell))")

        let json = CopyFormat.json.render(values)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: String]
        assert(parsed == values, "JSON 라운드트립")

        assert(CopyFormat.dotenv.render(["K": "v"]) == EnvParser.serialize(["K": "v"]), "dotenv는 §3.2 그대로")
    }

    // §3.17 — example 역생성: 전 Environment 합집합, 무시 키 제외, note 주석, 재파싱 시 diff 없음
    static func checkExampleContent() throws {
        let target = Target(relativePath: ".")
        let a = Variable(key: "API_URL", value: "https://prod", environmentName: "Production")
        let b = Variable(key: "SECRET_KEY", value: "", environmentName: "Local")
        b.note = "발급: 팀 위키 참고"
        b.isSecret = true
        let ignored = Variable(key: "IGNORED_KEY", value: "x", environmentName: "Local")
        ignored.isIgnored = true
        target.variables = [a, b, ignored]

        let content = ExampleDiffService.exampleContent(for: target)
        assert(content == """
            API_URL=
            # 발급: 팀 위키 참고
            SECRET_KEY=

            """, "example 내용 (got \(content))")

        // §3.17 수용 기준: Secret 키 포함·값 비어 있음, 재스캔 diff 없음(키 집합 동일)
        let keys = ExampleDiffService.keys(of: content)
        assert(keys == ["API_URL", "SECRET_KEY"], "역생성 키 집합 (got \(keys))")
        assert(EnvParser.parse(content).entries.allSatisfy { $0.value.isEmpty }, "값은 모두 빈 문자열")
    }

    // §3.18 — output drift
    static func checkDrift() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("phase5-drift-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let repo = Repository(name: "demo")
        let target = Target(relativePath: ".")
        target.repository = repo
        repo.targets = [target]
        let outputURL = root.appendingPathComponent(target.outputPath)

        // Generate한 적 없음(outputHash == nil) → 검사 제외
        try "A=1\n".write(to: outputURL, atomically: true, encoding: .utf8)
        assert(GenerateService.checkDrift(repo: repo, rootURL: root).isEmpty, "outputHash nil은 제외")

        // Generate 직후 → drift 없음
        target.outputHash = GenerateService.sha256("A=1\n")
        assert(GenerateService.checkDrift(repo: repo, rootURL: root).isEmpty, "Generate 직후 drift 없음")

        // 외부 수정 → drift
        try "A=changed\n".write(to: outputURL, atomically: true, encoding: .utf8)
        let drifted = GenerateService.checkDrift(repo: repo, rootURL: root)
        assert(drifted.count == 1 && drifted[0].fileExists && drifted[0].fileContent == "A=changed\n",
               "외부 수정 감지 (got \(drifted))")

        // 삭제 → drift (fileExists false)
        try fm.removeItem(at: outputURL)
        let deleted = GenerateService.checkDrift(repo: repo, rootURL: root)
        assert(deleted.count == 1 && !deleted[0].fileExists, "삭제도 drift")
    }

    // §3.19 — 마커 블록 삽입/교체/제거 (순수 문자열)
    static func checkHookBlockEditing() throws {
        let fresh = GitSafetyService.insertingHookBlock(into: nil)
        assert(fresh.hasPrefix("#!/bin/sh\n"), "새 파일은 shebang")
        assert(fresh.contains(GitSafetyService.hookBeginMarker) && fresh.contains(GitSafetyService.hookEndMarker), "마커 포함")

        let husky = "#!/bin/sh\n. husky.sh\nnpm test\n"
        let appended = GitSafetyService.insertingHookBlock(into: husky)
        assert(appended.hasPrefix(husky), "기존 내용 보존")

        // 재설치 → 블록 교체 (중복 없음)
        let twice = GitSafetyService.insertingHookBlock(into: appended)
        assert(twice.components(separatedBy: GitSafetyService.hookBeginMarker).count == 2, "블록은 하나만")

        // 제거 → 원본 복원
        let removed = GitSafetyService.removingHookBlock(from: appended)
        assert(removed == husky, "제거 시 기존 내용만 남음 (got \(removed ?? "nil"))")
        assert(GitSafetyService.removingHookBlock(from: husky) == nil, "마커 없으면 nil")
    }

    // §3.19 — core.hooksPath(husky) 반영한 파일 설치/제거
    static func checkHookFileOps() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("phase5-hook-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "[core]\n\thooksPath = .husky\n".write(
            to: root.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent(".husky"), withIntermediateDirectories: true)
        let hookURL = root.appendingPathComponent(".husky/pre-commit")
        let husky = "#!/bin/sh\nnpm test\n"
        try husky.write(to: hookURL, atomically: true, encoding: .utf8)

        assert(GitSafetyService.preCommitHookURL(rootURL: root)?.path == hookURL.path, "core.hooksPath 반영")
        assert(!GitSafetyService.isHookInstalled(rootURL: root), "설치 전")

        try GitSafetyService.installHook(rootURL: root)
        assert(GitSafetyService.isHookInstalled(rootURL: root), "설치 후")
        let perms = try fm.attributesOfItem(atPath: hookURL.path)[.posixPermissions] as! NSNumber
        assert(perms.intValue & 0o111 != 0, "실행 권한")

        try GitSafetyService.removeHook(rootURL: root)
        let afterRemove = try String(contentsOf: hookURL, encoding: .utf8)
        assert(afterRemove == husky, "제거 후 husky 내용 보존 (got \(afterRemove))")
    }

    // §3.19 수용 기준 — 실제 git 저장소에서 .env.local 커밋이 차단된다
    static func checkHookBlocksRealCommit() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("phase5-git-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        @discardableResult
        func git(_ args: [String]) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root.path, "-c", "user.email=t@t", "-c", "user.name=t"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }

        try git(["init", "-q"])
        try GitSafetyService.installHook(rootURL: root)

        try "SECRET=1\n".write(to: root.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        try git(["add", ".env.local"])
        let leakStatus = try git(["commit", "-q", "-m", "leak"])
        assert(leakStatus != 0, ".env.local 커밋은 차단")

        try git(["reset", "-q"])
        try "KEY=\n".write(to: root.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
        try "readme\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", ".env.example", "README.md"])
        let okStatus = try git(["commit", "-q", "-m", "ok"])
        assert(okStatus == 0, "example과 일반 파일은 허용")
    }
}
