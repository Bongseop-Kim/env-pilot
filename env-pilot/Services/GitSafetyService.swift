import Foundation
import SwiftData

/// 출력 파일의 Git 안전성 검사 (PRD §3.11).
/// ponytail: 간이 gitignore 매칭(fnmatch) + .git/index 바이트 검색 — git CLI는 샌드박스
/// 자식 프로세스 권한 문제가 있어 미사용. negation(!) 패턴 등 완전 호환은 아님.
enum GitSafetyService {

    struct Report: Identifiable {
        let targetPath: String
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
            .sorted { $0.relativePath < $1.relativePath }
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

                return Report(targetPath: target.relativePath, outputRelativePath: relativePath,
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
