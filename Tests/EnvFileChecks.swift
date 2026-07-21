// 사용자가 요청한 실제 .env 파일 생성·이름/경로 변경·삭제 검증.
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/EnvParser.swift \
//       env-pilot/Services/GitInfo.swift env-pilot/Services/GitSafetyService.swift \
//       env-pilot/Services/SecretStore.swift env-pilot/Services/VariableService.swift \
//       env-pilot/Services/ImportService.swift env-pilot/Services/LocalSyncService.swift \
//       env-pilot/Services/EnvFileService.swift Tests/EnvFileChecks.swift \
//       -o /tmp/env-file-check && /tmp/env-file-check

import Foundation
import SwiftData

@main
struct EnvFileChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("env-file-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("apps/api"),
                               withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: Schema([Workspace.self, HistoryEntry.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let repo = Repository(name: "files")
        context.insert(repo)
        try context.save()
        defer { LocalSyncService.clearLocalState(for: repo) }

        let rootLocation = try EnvFileService.location(for: ".env")
        let nestedLocation = try EnvFileService.location(for: "apps/api/.env.production")
        assert(rootLocation
            == .init(relativePath: ".env", directoryPath: ".", fileName: ".env"))
        assert(nestedLocation
            == .init(relativePath: "apps/api/.env.production",
                     directoryPath: "apps/api", fileName: ".env.production"))
        for invalidPath in ["", "/.env", "../.env", "apps//.env", ".env.example", "config.env",
                            "node_modules/pkg/.env"] {
            do {
                _ = try EnvFileService.location(for: invalidPath)
                assertionFailure("잘못된 경로를 허용하면 안 됨: \(invalidPath)")
            } catch {}
        }

        let target = try EnvFileService.create(
            relativePath: ".env.local", in: repo, rootURL: root, context: context)
        let originalURL = root.appendingPathComponent(".env.local")
        assert(fm.fileExists(atPath: originalURL.path), "빈 env 파일 생성")
        let permissions = try fm.attributesOfItem(atPath: originalURL.path)[.posixPermissions] as? NSNumber
        assert(permissions?.intValue == 0o600, "생성 파일 권한 0600")
        assert(target.envFilePath == ".env.local", "Target 경로 저장")
        assert(LocalSyncService.localCheckpoint(
            repoUUID: repo.uuid, relativePath: ".", outputPath: ".env.local")
            == LocalSyncService.sha256(""), "빈 파일 기준점 저장")

        do {
            _ = try EnvFileService.create(
                relativePath: ".env.local", in: repo, rootURL: root, context: context)
            assertionFailure("중복 파일 생성을 막아야 함")
        } catch {}
        do {
            _ = try EnvFileService.create(
                relativePath: "missing/.env", in: repo, rootURL: root, context: context)
            assertionFailure("없는 상위 폴더에는 만들 수 없어야 함")
        } catch {}

        let plain = try VariableService.create(
            key: "PUBLIC_VALUE", value: "one", environmentName: target.envFilePath,
            target: target, context: context)
        let secret = try VariableService.create(
            key: "SECRET_VALUE", value: "two", isSecret: true,
            environmentName: target.envFilePath, target: target, context: context)
        let oldSecretAccount = SecretStore.account(
            repoUUID: repo.uuid, targetPath: ".", environmentName: ".env.local", key: secret.key)
        let sync = LocalSyncService.reconcile(repo: repo, rootURL: root, context: context)
        assert(sync.isSynced, "생성 직후 변수 변경을 파일에 반영")
        let checkpoint = LocalSyncService.localCheckpoint(
            repoUUID: repo.uuid, relativePath: ".", outputPath: ".env.local")

        try EnvFileService.rename(
            target, to: "apps/api/.env.production", rootURL: root, context: context)
        let renamedURL = root.appendingPathComponent("apps/api/.env.production")
        assert(!fm.fileExists(atPath: originalURL.path) && fm.fileExists(atPath: renamedURL.path),
               "실제 파일 이름/경로 변경")
        assert(target.envFilePath == "apps/api/.env.production", "Target 경로 변경")
        assert(plain.environmentName == target.envFilePath && secret.environmentName == target.envFilePath,
               "변수 scope 변경")
        let newSecretAccount = SecretStore.account(
            repoUUID: repo.uuid, targetPath: "apps/api",
            environmentName: "apps/api/.env.production", key: secret.key)
        assert(SecretStore.read(account: oldSecretAccount) == nil, "이전 Secret 식별자 정리")
        assert(SecretStore.read(account: newSecretAccount) == "two", "새 Secret 식별자로 이전")
        assert(LocalSyncService.localCheckpoint(
            repoUUID: repo.uuid, relativePath: "apps/api", outputPath: ".env.production") == checkpoint,
            "이름 변경 후 동기화 기준점 유지")

        try EnvFileService.delete(target, rootURL: root, context: context)
        assert(!fm.fileExists(atPath: renamedURL.path), "실제 파일 삭제")
        let targetCount = try context.fetchCount(FetchDescriptor<Target>())
        let variableCount = try context.fetchCount(FetchDescriptor<Variable>())
        let historyCount = try context.fetchCount(FetchDescriptor<HistoryEntry>())
        assert(targetCount == 0, "Target 삭제")
        assert(variableCount == 0, "변수 cascade 삭제")
        assert(historyCount == 4,
               "변수 생성·파일 삭제 이력 보존")
        assert(SecretStore.read(account: newSecretAccount) == nil, "삭제한 파일의 Secret 정리")
        assert(LocalSyncService.localCheckpoint(
            repoUUID: repo.uuid, relativePath: "apps/api", outputPath: ".env.production") == nil,
            "삭제한 파일의 동기화 기준점 정리")

        let staleTarget = Target(relativePath: "removed/folder")
        staleTarget.outputPath = ".env"
        staleTarget.repository = repo
        context.insert(staleTarget)
        try context.save()
        try EnvFileService.delete(staleTarget, rootURL: root, context: context)
        let remainingTargets = try context.fetch(FetchDescriptor<Target>())
        assert(remainingTargets.isEmpty, "상위 폴더까지 사라진 관리 항목도 삭제")

        let gitRoot = root.appendingPathComponent("git-repo")
        try fm.createDirectory(at: gitRoot.appendingPathComponent(".git"),
                               withIntermediateDirectories: true)
        try ".env.local\n".write(
            to: gitRoot.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let gitRepo = Repository(name: "git-files")
        context.insert(gitRepo)
        try context.save()
        let ignoredTarget = try EnvFileService.create(
            relativePath: ".env.local", in: gitRepo, rootURL: gitRoot, context: context)
        do {
            try EnvFileService.rename(
                ignoredTarget, to: ".env.production", rootURL: gitRoot, context: context)
            assertionFailure("Git에서 무시되지 않는 경로로 Secret 파일을 옮기면 안 됨")
        } catch {}
        assert(fm.fileExists(atPath: gitRoot.appendingPathComponent(".env.local").path),
               "안전하지 않은 이름 변경 시 원본 보존")
        try EnvFileService.delete(ignoredTarget, rootURL: gitRoot, context: context)
        LocalSyncService.clearLocalState(for: gitRepo)

        print("✅ EnvFileService: all checks passed")
    }
}
