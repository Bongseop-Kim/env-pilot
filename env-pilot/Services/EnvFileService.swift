import Foundation
import SwiftData

/// 사용자가 명시적으로 요청한 실제 .env 파일 생성·이름 변경·삭제.
enum EnvFileService {

    struct Location: Equatable {
        let relativePath: String
        let directoryPath: String
        let fileName: String
    }

    enum EnvFileError: LocalizedError {
        case invalidPath
        case unsupportedFileName(String)
        case excludedDirectory(String)
        case directoryNotFound(String)
        case symbolicLinkDirectory(String)
        case alreadyExists(String)
        case alreadyManaged(String)
        case sourceNotFound(String)
        case repositoryNotFound
        case secretUnavailable(String)
        case destinationNotIgnored(String)
        case destinationTracked(String)
        case cannotCreate(String)
        case fileOperation(String, Error)
        case persistence(Error)

        var errorDescription: String? {
            switch self {
            case .invalidPath:
                "Repository 안의 상대 경로를 입력하세요. '.'과 '..'은 사용할 수 없습니다."
            case .unsupportedFileName(let name):
                "지원하지 않는 파일명입니다: \(name) (.env 또는 .env.* 값 파일만 가능)"
            case .excludedDirectory(let path):
                "관리 대상에서 제외된 폴더입니다: \(path)"
            case .directoryNotFound(let path):
                "상위 폴더가 없습니다: \(path)"
            case .symbolicLinkDirectory(let path):
                "심볼릭 링크 폴더에는 env 파일을 만들거나 이동할 수 없습니다: \(path)"
            case .alreadyExists(let path):
                "이미 파일이 존재합니다: \(path)"
            case .alreadyManaged(let path):
                "이미 관리 중인 env 파일입니다: \(path)"
            case .sourceNotFound(let path):
                "변경할 파일을 찾을 수 없습니다: \(path)"
            case .repositoryNotFound:
                "Repository 정보를 찾을 수 없습니다."
            case .secretUnavailable(let key):
                "\(key) Secret의 iCloud Keychain 동기화를 기다린 뒤 다시 시도하세요."
            case .destinationNotIgnored(let path):
                "\(path)을 .gitignore에 먼저 추가하세요."
            case .destinationTracked(let path):
                "\(path)이 Git에 tracked 상태라 이름을 변경할 수 없습니다."
            case .cannotCreate(let path):
                "파일을 만들 수 없습니다: \(path)"
            case .fileOperation(let action, let error):
                "파일 \(action) 실패: \(error.localizedDescription)"
            case .persistence(let error):
                "env 파일 정보 저장 실패: \(error.localizedDescription)"
            }
        }
    }

    static func location(for input: String) throws -> Location {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = try directoryComponents(path)
        guard let fileName = components.last else {
            throw EnvFileError.invalidPath
        }
        guard LocalSyncService.isManagedEnvFileName(fileName) else {
            throw EnvFileError.unsupportedFileName(fileName)
        }
        if let excluded = components.dropLast().first(where: {
            LocalSyncService.skippedDirectoryNames.contains($0)
        }) {
            throw EnvFileError.excludedDirectory(excluded)
        }

        let directoryPath = components.count == 1
            ? "."
            : components.dropLast().joined(separator: "/")
        return Location(relativePath: components.joined(separator: "/"),
                        directoryPath: directoryPath,
                        fileName: fileName)
    }

    @discardableResult
    static func create(relativePath: String, in repo: Repository, rootURL: URL,
                       context: ModelContext) throws -> Target {
        let location = try location(for: relativePath)
        guard !(repo.targets ?? []).contains(where: { $0.envFilePath == location.relativePath }) else {
            throw EnvFileError.alreadyManaged(location.relativePath)
        }

        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        let directoryURL = try existingDirectoryURL(for: location.directoryPath, rootURL: rootURL)
        let fileURL = directoryURL.appendingPathComponent(location.fileName)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw EnvFileError.alreadyExists(location.relativePath)
        }
        guard FileManager.default.createFile(
            atPath: fileURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]
        ) else {
            throw EnvFileError.cannotCreate(location.relativePath)
        }

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw EnvFileError.fileOperation("권한 설정", error)
        }

        let target = Target(relativePath: location.directoryPath)
        target.outputPath = location.fileName
        target.examplePath = ".env.example"
        target.repository = repo
        context.insert(target)
        do {
            try context.save()
        } catch {
            context.delete(target)
            try? FileManager.default.removeItem(at: fileURL)
            throw EnvFileError.persistence(error)
        }

        LocalSyncService.setLocalCheckpoint(
            LocalSyncService.sha256(""), repoUUID: repo.uuid,
            relativePath: target.relativePath, outputPath: target.outputPath)
        return target
    }

    static func rename(_ target: Target, to relativePath: String, rootURL: URL,
                       context: ModelContext) throws {
        guard let repo = target.repository else { throw EnvFileError.repositoryNotFound }
        let destination = try location(for: relativePath)
        let oldDirectoryPath = target.relativePath
        let oldFileName = target.outputPath
        let oldFilePath = target.envFilePath
        guard destination.relativePath != oldFilePath else { return }
        guard !(repo.targets ?? []).contains(where: {
            $0 !== target && $0.envFilePath == destination.relativePath
        }) else {
            throw EnvFileError.alreadyManaged(destination.relativePath)
        }

        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        let sourceDirectoryURL = try existingDirectoryURL(for: oldDirectoryPath, rootURL: rootURL)
        let sourceURL = sourceDirectoryURL.appendingPathComponent(oldFileName)
        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory),
              !sourceIsDirectory.boolValue else {
            throw EnvFileError.sourceNotFound(oldFilePath)
        }

        let destinationDirectoryURL = try existingDirectoryURL(
            for: destination.directoryPath, rootURL: rootURL)
        let destinationURL = destinationDirectoryURL.appendingPathComponent(destination.fileName)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw EnvFileError.alreadyExists(destination.relativePath)
        }

        target.relativePath = destination.directoryPath
        target.outputPath = destination.fileName
        let destinationSafety = GitSafetyService.check(repo: repo, rootURL: rootURL)
            .first { $0.targetPath == destination.relativePath }
        target.relativePath = oldDirectoryPath
        target.outputPath = oldFileName
        if let destinationSafety, !destinationSafety.isIgnored {
            throw EnvFileError.destinationNotIgnored(destination.relativePath)
        }
        if let destinationSafety, destinationSafety.isTracked {
            throw EnvFileError.destinationTracked(destination.relativePath)
        }

        let variables = target.variables ?? []
        let migrations = try secretMigrations(
            variables: variables,
            repoUUID: repo.uuid,
            oldDirectoryPath: oldDirectoryPath,
            oldFilePath: oldFilePath,
            newDirectoryPath: destination.directoryPath,
            newFilePath: destination.relativePath)
        var preparedAccounts: [String] = []
        do {
            for migration in migrations where migration.oldAccount != migration.newAccount {
                try SecretStore.save(migration.value, account: migration.newAccount)
                preparedAccounts.append(migration.newAccount)
            }
        } catch {
            preparedAccounts.forEach { SecretStore.delete(account: $0) }
            throw error
        }

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            preparedAccounts.forEach { SecretStore.delete(account: $0) }
            throw EnvFileError.fileOperation("이름 변경", error)
        }

        let scopedVariables = variables.filter { $0.environmentName == oldFilePath }
        target.relativePath = destination.directoryPath
        target.outputPath = destination.fileName
        scopedVariables.forEach { $0.environmentName = destination.relativePath }
        do {
            try context.save()
        } catch {
            target.relativePath = oldDirectoryPath
            target.outputPath = oldFileName
            scopedVariables.forEach { $0.environmentName = oldFilePath }
            try? FileManager.default.moveItem(at: destinationURL, to: sourceURL)
            preparedAccounts.forEach { SecretStore.delete(account: $0) }
            throw EnvFileError.persistence(error)
        }

        migrations.filter { $0.oldAccount != $0.newAccount }
            .forEach { SecretStore.delete(account: $0.oldAccount) }

        let checkpoint = LocalSyncService.localCheckpoint(
            repoUUID: repo.uuid, relativePath: oldDirectoryPath, outputPath: oldFileName)
        LocalSyncService.setLocalCheckpoint(
            nil, repoUUID: repo.uuid, relativePath: oldDirectoryPath, outputPath: oldFileName)
        LocalSyncService.setLocalCheckpoint(
            checkpoint, repoUUID: repo.uuid,
            relativePath: destination.directoryPath, outputPath: destination.fileName)
    }

    static func delete(_ target: Target, rootURL: URL, context: ModelContext) throws {
        guard let repo = target.repository else { throw EnvFileError.repositoryNotFound }
        let directoryPath = target.relativePath
        let fileName = target.outputPath

        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        let fileURL = try uncheckedFileURL(
            directoryPath: directoryPath, fileName: fileName, rootURL: rootURL)
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        if fileExists {
            _ = try existingDirectoryURL(for: directoryPath, rootURL: rootURL)
        }
        let backupData: Data?
        if fileExists {
            do { backupData = try Data(contentsOf: fileURL) }
            catch { throw EnvFileError.fileOperation("읽기", error) }
        } else {
            backupData = nil
        }
        let backupPermissions = fileExists
            ? (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions])
            : nil

        if fileExists {
            do { try FileManager.default.removeItem(at: fileURL) }
            catch { throw EnvFileError.fileOperation("삭제", error) }
        }

        let variables = target.variables ?? []
        let secretBackups = variables.compactMap { variable -> (account: String, value: String)? in
            guard variable.isSecret else { return nil }
            let account = SecretStore.account(
                repoUUID: repo.uuid,
                targetPath: directoryPath,
                environmentName: variable.environmentName,
                key: variable.key)
            guard let value = SecretStore.read(account: account) else { return nil }
            return (account, value)
        }

        do {
            for variable in variables {
                try VariableService.delete(variable, context: context, saveChanges: false)
            }
            context.delete(target)
            try context.save()
        } catch {
            context.rollback()
            for backup in secretBackups {
                try? SecretStore.save(backup.value, account: backup.account)
            }
            if let backupData {
                try? backupData.write(to: fileURL, options: .atomic)
                if let backupPermissions {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: backupPermissions], ofItemAtPath: fileURL.path)
                }
            }
            throw EnvFileError.persistence(error)
        }

        LocalSyncService.setLocalCheckpoint(
            nil, repoUUID: repo.uuid, relativePath: directoryPath, outputPath: fileName)
    }

    private struct SecretMigration {
        let oldAccount: String
        let newAccount: String
        let value: String
    }

    private static func secretMigrations(variables: [Variable], repoUUID: String,
                                         oldDirectoryPath: String, oldFilePath: String,
                                         newDirectoryPath: String, newFilePath: String) throws
        -> [SecretMigration] {
        try variables.compactMap { variable in
            guard variable.isSecret else { return nil }
            let newEnvironmentName = variable.environmentName == oldFilePath
                ? newFilePath
                : variable.environmentName
            let oldAccount = SecretStore.account(
                repoUUID: repoUUID, targetPath: oldDirectoryPath,
                environmentName: variable.environmentName, key: variable.key)
            let newAccount = SecretStore.account(
                repoUUID: repoUUID, targetPath: newDirectoryPath,
                environmentName: newEnvironmentName, key: variable.key)
            guard let value = SecretStore.read(account: oldAccount) else {
                throw EnvFileError.secretUnavailable(variable.key)
            }
            return SecretMigration(oldAccount: oldAccount, newAccount: newAccount, value: value)
        }
    }

    private static func existingDirectoryURL(for relativePath: String, rootURL: URL) throws -> URL {
        var url = rootURL.standardizedFileURL
        guard relativePath != "." else { return url }

        let components = try directoryComponents(relativePath)
        for component in components {
            url.appendPathComponent(String(component), isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw EnvFileError.directoryNotFound(relativePath)
            }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw EnvFileError.symbolicLinkDirectory(relativePath)
            }
        }
        return url
    }

    private static func uncheckedFileURL(directoryPath: String, fileName: String,
                                         rootURL: URL) throws -> URL {
        var url = rootURL.standardizedFileURL
        if directoryPath != "." {
            for component in try directoryComponents(directoryPath) {
                url.appendPathComponent(component, isDirectory: true)
            }
        }
        return url.appendingPathComponent(fileName)
    }

    private static func directoryComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              relativePath.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw EnvFileError.invalidPath
        }
        let components = relativePath.split(
            separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw EnvFileError.invalidPath
        }
        return components
    }
}
