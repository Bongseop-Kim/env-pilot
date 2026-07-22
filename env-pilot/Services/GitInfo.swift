import Foundation

/// Git 저장소 메타 정보 읽기 (PRD §3.1).
/// ponytail: git CLI 대신 .git 파일 직접 파싱 — 샌드박스에서 자식 프로세스 권한 문제가 없고,
/// §3.1에 필요한 건 remote/branch뿐. check-ignore 등이 필요한 Phase 3에서 CLI 여부 재검토.
struct GitInfo {
    var remoteURL: String?     // [remote "origin"]의 url
    var currentBranch: String? // HEAD가 가리키는 브랜치, detached면 nil

    /// 폴더가 Git 저장소가 아니면 nil.
    static func read(at folderURL: URL) -> GitInfo? {
        guard let gitDir = gitDirectory(of: folderURL) else { return nil }

        var info = GitInfo()

        // HEAD: "ref: refs/heads/main"
        if let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) {
            let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("ref: refs/heads/") {
                info.currentBranch = String(line.dropFirst("ref: refs/heads/".count))
            }
        }

        // config: [remote "origin"] 섹션의 url =
        if let config = try? String(contentsOf: gitDir.appendingPathComponent("config"), encoding: .utf8) {
            info.remoteURL = configValue(config, section: "[remote\"origin\"]", key: "url")
        }

        return info
    }

    /// git config 텍스트에서 섹션의 키 값을 읽는다. 섹션 헤더는 공백 제거 후 비교, 키는 대소문자 무시.
    static func configValue(_ config: String, section: String, key: String) -> String? {
        var inSection = false
        for rawLine in config.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.replacingOccurrences(of: " ", with: "") == section
            } else if inSection, line.lowercased().hasPrefix(key.lowercased()),
                      let eq = line.firstIndex(of: "=") {
                return String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// .git이 디렉토리면 그대로, 파일이면(worktree) "gitdir: <path>" 해석. Git 저장소가 아니면 nil.
    static func gitDirectory(of folderURL: URL) -> URL? {
        let dotGit = folderURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }

        guard let content = try? String(contentsOf: dotGit, encoding: .utf8),
              content.hasPrefix("gitdir: ") else { return nil }
        let path = content.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : folderURL.appendingPathComponent(path).standardizedFileURL
    }
}
