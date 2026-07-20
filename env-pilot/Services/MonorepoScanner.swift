import Foundation

/// Monorepo Target 후보 탐색 (PRD §3.5).
/// pnpm-workspace.yaml 우선, 없으면 package.json workspaces (nx/turbo도 이 둘로 정의됨).
enum MonorepoScanner {

    struct Candidate: Equatable {
        let relativePath: String
        let hasExample: Bool
    }

    /// workspace glob을 해석해 package.json이 있는 디렉토리만 반환.
    /// node_modules/심볼릭 링크/숨김 폴더 제외 (§3.5 엣지 케이스).
    static func scan(rootURL: URL) -> [Candidate] {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        let globs = workspaceGlobs(rootURL: rootURL)
        guard !globs.isEmpty else { return [] }

        let fm = FileManager.default
        var seen = Set<String>()
        // workspace 루트 자체도 후보 — 루트에 .env.example을 두는 모노레포가 흔하다
        var candidates: [Candidate] = [Candidate(
            relativePath: ".",
            hasExample: fm.fileExists(atPath: rootURL.appendingPathComponent(".env.example").path)
        )]
        for glob in globs where !glob.hasPrefix("!") {   // negation 패턴은 무시
            for dir in resolve(glob: glob, root: rootURL) {
                let rel = String(dir.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1))
                guard !seen.contains(rel), !rel.contains("node_modules"),
                      fm.fileExists(atPath: dir.appendingPathComponent("package.json").path)
                else { continue }
                seen.insert(rel)
                candidates.append(Candidate(
                    relativePath: rel,
                    hasExample: fm.fileExists(atPath: dir.appendingPathComponent(".env.example").path)
                ))
            }
        }
        return candidates.sorted { $0.relativePath < $1.relativePath }
    }

    static func workspaceGlobs(rootURL: URL) -> [String] {
        if let yaml = try? String(contentsOf: rootURL.appendingPathComponent("pnpm-workspace.yaml"), encoding: .utf8) {
            let globs = parsePnpmPackages(yaml)
            if !globs.isEmpty { return globs }
        }
        if let data = try? Data(contentsOf: rootURL.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let list = json["workspaces"] as? [String] { return list }
            if let object = json["workspaces"] as? [String: Any],
               let list = object["packages"] as? [String] { return list }
        }
        return []
    }

    /// "apps/*", "apps/**" → apps의 하위 디렉토리들. glob 없는 리터럴 → 그 경로 자체.
    // ponytail: 단일 레벨 글롭만 지원 — 중첩 글롭(a/*/b)이 실제로 필요해지면 확장
    private static func resolve(glob: String, root: URL) -> [URL] {
        let fm = FileManager.default
        let cleaned = glob.hasSuffix("/**") ? String(glob.dropLast(3)) + "/*" : glob

        if cleaned.hasSuffix("/*") {
            let base = root.appendingPathComponent(String(cleaned.dropLast(2)))
            let children = (try? fm.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return children.filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
        }

        var isDirectory: ObjCBool = false
        let literal = root.appendingPathComponent(cleaned)
        return fm.fileExists(atPath: literal.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? [literal] : []
    }

    private static func parsePnpmPackages(_ yaml: String) -> [String] {
        var inPackages = false
        var globs: [String] = []
        for raw in yaml.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("packages:") { inPackages = true; continue }
            guard inPackages else { continue }
            if line.hasPrefix("- ") {
                globs.append(String(line.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
            } else if !line.isEmpty && !line.hasPrefix("#") {
                inPackages = false
            }
        }
        return globs
    }
}
