import Foundation
import SwiftData

/// 출력 파일의 Git 안전성 검사 (PRD §3.11).
/// ponytail: 간이 gitignore 매칭(fnmatch) + .git/index 바이트 검색 — git CLI는 샌드박스
/// 자식 프로세스 권한 문제가 있어 미사용. negation(!) 패턴 등 완전 호환은 아님.
enum GitSafetyService {

    struct Report: Identifiable {
        let targetPath: String           // 실제 env 파일의 Repository 상대 경로
        let outputRelativePath: String   // repo 루트 기준, 예: "apps/shop/.env.local"
        let outputExists: Bool
        let isIgnored: Bool
        let isTracked: Bool
        let permissionsOK: Bool?         // 파일 없으면 nil
        var id: String { targetPath }
        var hasIssue: Bool { !isIgnored || isTracked || permissionsOK == false }
    }

    static func check(repo: Repository, rootURL: URL) -> [Report] {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default

        // Git 저장소가 아니면 커밋 위험이 없으므로 이슈 없음 처리
        let gitDir = GitInfo.gitDirectory(of: rootURL)
        let indexData = gitDir.flatMap { try? Data(contentsOf: $0.appendingPathComponent("index")) }
        let rootPatterns = gitignorePatterns(at: rootURL)

        return (repo.targets ?? [])
            .sorted { $0.envFilePath < $1.envFilePath }
            .map { target in
                let isRoot = target.relativePath == "."
                let dir = isRoot ? rootURL : rootURL.appendingPathComponent(target.relativePath)
                let relativePath = isRoot
                    ? target.outputPath
                    : "\(target.relativePath)/\(target.outputPath)"
                let outputURL = dir.appendingPathComponent(target.outputPath)
                let exists = fm.fileExists(atPath: outputURL.path)

                var ignored = gitDir == nil  // 비 Git 저장소는 항상 안전
                if gitDir != nil {
                    var patterns = rootPatterns.map { (base: "", pattern: $0) }
                    if !isRoot {
                        patterns += gitignorePatterns(at: dir).map { (base: target.relativePath + "/", pattern: $0) }
                    }
                    ignored = isIgnored(relativePath: relativePath, patterns: patterns)
                }

                let tracked = indexData.map { $0.range(of: Data(relativePath.utf8)) != nil } ?? false

                var permissionsOK: Bool? = nil
                if exists, let perms = try? fm.attributesOfItem(atPath: outputURL.path)[.posixPermissions] as? NSNumber {
                    permissionsOK = perms.intValue == 0o600
                }

                return Report(targetPath: target.envFilePath, outputRelativePath: relativePath,
                              outputExists: exists, isIgnored: ignored, isTracked: tracked,
                              permissionsOK: permissionsOK)
            }
    }

    /// 루트 .gitignore에 한 줄 추가 (§3.11). 파일명 패턴은 gitignore 규칙상 모든 하위 경로에 적용된다.
    static func addToGitignore(line: String, rootURL: URL) throws {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        let url = rootURL.appendingPathComponent(".gitignore")
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += line + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func fixPermissions(outputURL: URL, rootURL: URL) throws {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
    }

    // MARK: - pre-commit hook (§3.19)

    static let hookBeginMarker = "# envide-guard begin"
    static let hookEndMarker = "# envide-guard end"

    /// 스테이징된 .env / .env.* (example 제외) 파일이 있으면 커밋 차단.
    static let hookBlock = """
        \(hookBeginMarker)
        # Env IDE가 설치한 .env 커밋 차단 블록 — 제거는 앱의 Health 탭에서.
        envide_blocked=$(git diff --cached --name-only | grep -E '(^|/)\\.env(\\..+)?$' | grep -vE '\\.example$' || true)
        if [ -n "$envide_blocked" ]; then
          echo "envide: .env 파일은 커밋할 수 없습니다:" >&2
          echo "$envide_blocked" >&2
          exit 1
        fi
        \(hookEndMarker)
        """

    /// core.hooksPath(husky 등)를 반영한 pre-commit 경로. Git 저장소가 아니면 nil.
    static func preCommitHookURL(rootURL: URL) -> URL? {
        guard let gitDir = GitInfo.gitDirectory(of: rootURL) else { return nil }
        var hooksDir = gitDir.appendingPathComponent("hooks")
        if let config = try? String(contentsOf: gitDir.appendingPathComponent("config"), encoding: .utf8),
           let path = parseHooksPath(config) {
            hooksDir = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : rootURL.appendingPathComponent(path).standardizedFileURL
        }
        return hooksDir.appendingPathComponent("pre-commit")
    }

    private static func parseHooksPath(_ config: String) -> String? {
        var inCore = false
        for rawLine in config.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inCore = line == "[core]"
            } else if inCore, line.lowercased().hasPrefix("hookspath"),
                      let eq = line.firstIndex(of: "=") {
                return String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 기존 hook 내용에 guard 블록 삽입. 이미 마커가 있으면 블록만 교체, 없으면 끝에 append (§3.19).
    static func insertingHookBlock(into existing: String?) -> String {
        guard var content = existing, !content.isEmpty else {
            return "#!/bin/sh\n\n" + hookBlock + "\n"
        }
        if let stripped = removingHookBlock(from: content) { content = stripped }
        if !content.hasSuffix("\n") { content += "\n" }
        return content + "\n" + hookBlock + "\n"
    }

    /// 마커 블록만 제거하고 나머지 내용 보존. 블록이 없으면 nil.
    static func removingHookBlock(from content: String) -> String? {
        guard let begin = content.range(of: hookBeginMarker),
              let end = content.range(of: hookEndMarker) else { return nil }
        var head = String(content[..<begin.lowerBound])
        let tail = String(content[end.upperBound...]).drop(while: { $0 == "\n" })
        while head.hasSuffix("\n\n") { head.removeLast() }
        return head + tail
    }

    static func isHookInstalled(rootURL: URL) -> Bool {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        guard let url = preCommitHookURL(rootURL: rootURL),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return content.contains(hookBeginMarker)
    }

    static func installHook(rootURL: URL) throws {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        guard let url = preCommitHookURL(rootURL: rootURL) else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        try insertingHookBlock(into: existing).write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func removeHook(rootURL: URL) throws {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        guard let url = preCommitHookURL(rootURL: rootURL),
              let content = try? String(contentsOf: url, encoding: .utf8),
              let stripped = removingHookBlock(from: content) else { return }
        try stripped.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - AI 에이전트 노출 검사 (1Password zero-exposure 모델 참고)
    // Claude Code는 permissions.deny로 강제 차단, 그 외 에이전트(Codex·Cursor·Gemini 등)는
    // 공통 규약 AGENTS.md의 지시 블록으로 커버.

    /// .claude 설정에 .env 읽기 차단(deny) 규칙이 있는지. .claude 디렉토리가 없으면 nil(해당 없음).
    static func claudeEnvDenyStatus(rootURL: URL) -> Bool? {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        let claudeDir = rootURL.appendingPathComponent(".claude")
        guard FileManager.default.fileExists(atPath: claudeDir.path) else { return nil }
        for name in ["settings.json", "settings.local.json"] {
            if let data = try? Data(contentsOf: claudeDir.appendingPathComponent(name)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               hasEnvDenyRule(json) {
                return true
            }
        }
        return false
    }

    /// permissions.deny 안에 .env를 언급하는 Read 차단 규칙이 있는지.
    static func hasEnvDenyRule(_ json: [String: Any]) -> Bool {
        let deny = (json["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
        return deny.contains { $0.hasPrefix("Read(") && $0.contains(".env") }
    }

    /// permissions.deny에 출력 파일명별 Read 차단 규칙 병합 (멱등). 나머지 설정은 보존.
    static func insertingClaudeDenyRules(into json: [String: Any], fileNames: [String]) -> [String: Any] {
        var json = json
        var permissions = json["permissions"] as? [String: Any] ?? [:]
        var deny = permissions["deny"] as? [String] ?? []
        for name in Set(fileNames).sorted() {
            let rule = "Read(**/\(name))"
            if !deny.contains(rule) { deny.append(rule) }
        }
        permissions["deny"] = deny
        json["permissions"] = permissions
        return json
    }

    /// .claude/settings.local.json에 차단 규칙 기록 (개인 설정 — 팀 공유 settings.json은 건드리지 않음).
    static func addClaudeEnvDenyRules(fileNames: [String], rootURL: URL) throws {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        let url = rootURL.appendingPathComponent(".claude/settings.local.json")
        let existing = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        let merged = insertingClaudeDenyRules(into: existing, fileNames: fileNames)
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: - AGENTS.md 공통 규칙 (Claude 외 모든 에이전트)

    static let agentsBeginMarker = "<!-- envide-guard begin -->"
    static let agentsEndMarker = "<!-- envide-guard end -->"

    /// 에이전트가 가장 잘 따르도록 영어로 작성 — AGENTS.md는 AI가 읽는 파일.
    static let agentsRuleBlock = """
        \(agentsBeginMarker)
        ## Environment files — do not read

        Never read, print, copy, or transmit the contents of `.env` / `.env.*` files \
        (except `*.example`) — they contain secrets. Refer to `.env.example` for key names.
        \(agentsEndMarker)
        """

    /// AGENTS.md에 .env 읽기 금지 블록이 있는지. 파일이 없으면 false(추가 가능).
    static func agentsMdEnvRuleStatus(rootURL: URL) -> Bool {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        let content = try? String(contentsOf: rootURL.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        return content?.contains(agentsBeginMarker) ?? false
    }

    /// AGENTS.md 끝에 규칙 블록 append (파일 없으면 생성, 이미 있으면 no-op — 멱등).
    static func addAgentsMdEnvRule(rootURL: URL) throws {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        let url = rootURL.appendingPathComponent("AGENTS.md")
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !content.contains(agentsBeginMarker) else { return }
        if !content.isEmpty {
            if !content.hasSuffix("\n") { content += "\n" }
            content += "\n"
        }
        try (content + agentsRuleBlock + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 간이 gitignore 매칭

    static func gitignorePatterns(at dir: URL) -> [String] {
        guard let content = try? String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8)
        else { return [] }
        return content.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
    }

    /// base는 패턴이 정의된 디렉토리의 repo 루트 기준 경로 ("" 또는 "apps/shop/").
    static func isIgnored(relativePath: String, patterns: [(base: String, pattern: String)]) -> Bool {
        let fileName = (relativePath as NSString).lastPathComponent
        for (base, rawPattern) in patterns {
            var pattern = rawPattern
            if pattern.hasSuffix("/") { continue }  // 디렉토리 전용 패턴은 파일 매칭에서 제외
            if pattern.hasPrefix("**/") { pattern = String(pattern.dropFirst(3)) }

            if pattern.contains("/") {
                // 경로 포함 패턴: base 기준 전체 경로 매칭
                let normalized = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
                if fnmatch(base + normalized, relativePath, 0) == 0 { return true }
            } else {
                // 파일명 패턴: 모든 레벨의 basename 매칭 (base 하위인 경우만)
                if relativePath.hasPrefix(base), fnmatch(pattern, fileName, 0) == 0 { return true }
            }
        }
        return false
    }
}
