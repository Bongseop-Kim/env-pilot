// GitInfo 자체 검증.
// 실행: swiftc -parse-as-library env-pilot/Services/GitInfo.swift Tests/GitInfoChecks.swift -o /tmp/gitinfo-check && /tmp/gitinfo-check

import Foundation

@main
struct GitInfoChecks {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("gitinfo-check-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: base) }

        // 일반 저장소
        let repo = base.appendingPathComponent("repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try """
        [core]
        \trepositoryformatversion = 0
        [remote "upstream"]
        \turl = git@github.com:other/x.git
        [remote "origin"]
        \turl = git@github.com:me/blog.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """.write(to: repo.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let info = GitInfo.read(at: repo)
        assert(info?.currentBranch == "main", "branch 파싱 (got \(String(describing: info?.currentBranch)))")
        assert(info?.remoteURL == "git@github.com:me/blog.git", "origin url 파싱 (got \(String(describing: info?.remoteURL)))")

        // detached HEAD → branch nil
        try "abc123def456\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        assert(GitInfo.read(at: repo)?.currentBranch == nil, "detached HEAD는 branch nil")

        // worktree: .git이 파일
        let wt = base.appendingPathComponent("worktree")
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        assert(GitInfo.read(at: wt)?.remoteURL == "git@github.com:me/blog.git", "worktree gitdir 해석")

        // Git 저장소 아님 → nil
        let plain = base.appendingPathComponent("plain")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        assert(GitInfo.read(at: plain) == nil, "비 Git 폴더는 nil")

        print("✅ GitInfo: all checks passed")
    }
}
