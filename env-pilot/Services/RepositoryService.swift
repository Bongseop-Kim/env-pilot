import Foundation
import SwiftData

/// Repository 등록/재연결 (PRD §3.1).
enum RepositoryService {

    enum RegistrationError: LocalizedError {
        case duplicatePath(String)
        case bookmarkFailed(Error)

        var errorDescription: String? {
            switch self {
            case .duplicatePath(let path): "이미 등록된 폴더입니다: \(path)"
            case .bookmarkFailed(let error): "폴더 접근 권한 저장 실패: \(error.localizedDescription)"
            }
        }
    }

    /// §3.13: 북마크는 기기별 값 — CloudKit에 올라가지 않도록 SwiftData 대신 UserDefaults에 저장.
    private static func bookmarkKey(_ repo: Repository) -> String { "bookmark.\(repo.uuid)" }

    /// fileImporter 등에서 받은 보안 스코프 URL로 Repository 등록.
    /// Git 저장소가 아니어도 등록은 허용 (Git 기능만 비활성, §3.1).
    @discardableResult
    static func register(folderURL: URL, workspace: Workspace, context: ModelContext) throws -> Repository {
        let path = folderURL.standardizedFileURL.path

        let existing = try context.fetch(FetchDescriptor<Repository>(
            predicate: #Predicate { $0.localPathDisplay == path }
        ))
        guard existing.isEmpty else { throw RegistrationError.duplicatePath(path) }

        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { folderURL.stopAccessingSecurityScopedResource() } }

        let bookmark: Data
        do {
            bookmark = try folderURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw RegistrationError.bookmarkFailed(error)
        }

        let git = GitInfo.read(at: folderURL)

        let repo = Repository(name: folderURL.lastPathComponent)
        repo.gitRemoteURL = git?.remoteURL
        repo.defaultBranch = git?.currentBranch
        repo.localPathDisplay = path
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey(repo))
        repo.workspace = workspace
        context.insert(repo)

        // 시작점으로 기본 4종 — 프로젝트에 맞게 Settings에서 추가/삭제
        for (i, name) in Workspace.defaultEnvironmentNames.enumerated() {
            let env = EnvEnvironment(name: name, sortOrder: i)
            env.repository = repo
            context.insert(env)
        }

        let rootTarget = Target.makeWithDefaults(relativePath: ".")
        rootTarget.repository = repo
        context.insert(rootTarget)

        try context.save()
        return repo
    }

    /// 저장된 북마크 해석. stale이면 nil — UI에서 "경로 재연결" 유도 (§3.1).
    /// 반환된 URL은 사용 전 startAccessingSecurityScopedResource 필요.
    static func resolveBookmark(_ repo: Repository) -> URL? {
        var bookmark = UserDefaults.standard.data(forKey: bookmarkKey(repo))
        if bookmark == nil, let legacy = repo.localPathBookmark {
            // Phase 3까지는 모델에 저장 — UserDefaults로 이전하고 모델에서 비움 (mainContext 자동 저장)
            UserDefaults.standard.set(legacy, forKey: bookmarkKey(repo))
            repo.localPathBookmark = nil
            bookmark = legacy
        }
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return stale ? nil : url
    }

    /// 재연결: 사용자가 폴더를 다시 선택하면 북마크/git 정보 갱신.
    static func relink(repo: Repository, folderURL: URL, context: ModelContext) throws {
        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { folderURL.stopAccessingSecurityScopedResource() } }

        let bookmark = try folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey(repo))
        repo.localPathBookmark = nil  // 레거시 저장분 제거 (§3.13 동기화 제외)
        repo.localPathDisplay = folderURL.standardizedFileURL.path
        if let git = GitInfo.read(at: folderURL) {
            repo.gitRemoteURL = git.remoteURL
            repo.defaultBranch = git.currentBranch
        }
        try context.save()
    }
}
