import Foundation
import SwiftData
import CryptoKit
import Dispatch
import Darwin
import CoreServices

extension Notification.Name {
    static let localEnvFileDidChange = Notification.Name("envPilot.localEnvFileDidChange")
    static let localSyncConfigurationDidChange = Notification.Name("envPilot.localSyncConfigurationDidChange")
}

/// Repository 안의 실제 .env 파일과 Env Pilot 값을 자동으로 맞춘다.
enum LocalSyncService {

    struct EnvFile: Equatable {
        let relativePath: String
        let directoryPath: String
        let fileName: String
    }

    enum Decision: Equatable {
        case synced
        case writePilot
        case adoptLocal
        case conflict
    }

    struct Drift: Identifiable {
        enum Reason: Equatable { case changed, deleted, invalid }

        let target: Target
        let outputURL: URL
        let fileExists: Bool
        let fileContent: String?
        let reason: Reason
        var id: String { target.envFilePath }

        var message: String {
            switch reason {
            case .changed: "파일 내용과 Env Pilot 값이 다릅니다"
            case .deleted: "프로젝트에서 파일이 삭제되었습니다"
            case .invalid: "파일 형식을 읽을 수 없습니다"
            }
        }
    }

    struct ReconcileResult {
        var drifts: [Drift] = []
        var issues: [String] = []
        var changed = false
        var isSynced = false
        var safety: [GitSafetyService.Report] = []  // reconcile이 이미 계산한 안전성 리포트 — 호출부 재계산 방지
    }

    static let skippedDirectoryNames: Set<String> = [
        ".git", ".build", ".next", ".swiftpm", ".venv",
        "node_modules", "DerivedData", "Pods", "build", "dist"
    ]

    private static func checkpointKey(repoUUID: String, relativePath: String, outputPath: String) -> String {
        "envSync.hash.\(repoUUID).\(relativePath).\(outputPath)"
    }

    private static func checkpointKey(_ target: Target) -> String {
        checkpointKey(repoUUID: target.repository?.uuid ?? "-",
                      relativePath: target.relativePath,
                      outputPath: target.outputPath)
    }

    /// 파일 생성·이름 변경에서도 동기화 기준점을 안전하게 이어갈 수 있게 한다.
    static func localCheckpoint(repoUUID: String, relativePath: String, outputPath: String) -> String? {
        UserDefaults.standard.string(forKey: checkpointKey(
            repoUUID: repoUUID, relativePath: relativePath, outputPath: outputPath))
    }

    static func setLocalCheckpoint(_ checkpoint: String?, repoUUID: String,
                                   relativePath: String, outputPath: String) {
        let key = checkpointKey(repoUUID: repoUUID, relativePath: relativePath, outputPath: outputPath)
        if let checkpoint {
            UserDefaults.standard.set(checkpoint, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func clearLocalState(for repo: Repository) {
        UserDefaults.standard.removeObject(forKey: "envSync.active.\(repo.uuid)")
        for target in repo.targets ?? [] {
            setLocalCheckpoint(nil, repoUUID: repo.uuid,
                               relativePath: target.relativePath, outputPath: target.outputPath)
        }
    }

    /// 실제 값 파일만 찾는다. example/sample/template 파일과 의존성·빌드 폴더는 제외한다.
    static func discoverEnvFiles(rootURL: URL) -> [EnvFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let rootPath = rootURL.standardizedFileURL.path
        var files: [EnvFile] = []

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if values?.isSymbolicLink == true || skippedDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  isManagedEnvFileName(url.lastPathComponent) else { continue }

            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            let directory = (relativePath as NSString).deletingLastPathComponent
            files.append(EnvFile(
                relativePath: relativePath,
                directoryPath: directory.isEmpty ? "." : directory,
                fileName: url.lastPathComponent
            ))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    static func isManagedEnvFileName(_ name: String) -> Bool {
        guard name == ".env" || (name.hasPrefix(".env.") && name.count > 5) else { return false }
        guard name != ".env" else { return true }
        let suffix = String(name.dropFirst(5)).lowercased()
        let templates: Set<String> = ["example", "sample", "template", "dist", "schema"]
        return templates.isDisjoint(with: suffix.split(separator: ".").map(String.init))
    }

    /// 마지막 합의 상태를 기준으로 어느 쪽을 반영할지 정한다.
    static func decision(baseline: String?, pilot: String, local: String?) -> Decision {
        if local == pilot { return .synced }
        guard let baseline else { return local == nil ? .writePilot : .conflict }
        if local == baseline { return .writePilot }
        if pilot == baseline { return .adoptLocal }
        return .conflict
    }

    /// 앱/CloudKit 변경은 해당 실제 파일에 쓰고, 안전한 로컬 추가·수정은 앱으로 흡수한다.
    /// 삭제·동시 변경·파싱 오류는 자동 처리하지 않고 Drift로 돌려준다.
    static func reconcile(repo: Repository, rootURL: URL,
                          context: ModelContext? = nil) -> ReconcileResult {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var result = ReconcileResult()
        let refreshed = refreshTargets(repo: repo, rootURL: rootURL, context: context)
        let targets = refreshed.targets
        result.changed = refreshed.changed
        var verifiedTargets = 0

        if refreshed.changed, let context {
            do { try context.save() }
            catch { result.issues.append(".env 파일 목록 저장 실패: \(error.localizedDescription)") }
        }

        let safetyReports = GitSafetyService.check(repo: repo, rootURL: rootURL)
        result.safety = safetyReports
        var safety: [String: GitSafetyService.Report] = [:]
        for report in safetyReports {
            safety[report.targetPath] = report
        }

        for target in targets {
            let dir = target.relativePath == "."
                ? rootURL
                : rootURL.appendingPathComponent(target.relativePath)
            let outputURL = dir.appendingPathComponent(target.outputPath)
            guard fm.fileExists(atPath: dir.path) else {
                result.issues.append("\(target.envFilePath): 상위 폴더가 없습니다")
                continue
            }

            let variables = (target.variables ?? []).filter {
                $0.environmentName == target.envFilePath && !$0.isIgnored
            }
            let missingSecrets = variables.filter { $0.isSecret && VariableService.valueIfAvailable(of: $0) == nil }
            guard missingSecrets.isEmpty else {
                result.issues.append("\(target.envFilePath): iCloud Keychain 동기화를 기다리는 Secret이 있습니다")
                continue
            }
            let values = Dictionary(uniqueKeysWithValues: variables.map {
                ($0.key, VariableService.valueIfAvailable(of: $0) ?? "")
            })
            let pilotContent = EnvParser.serialize(values)
            let pilotHash = sha256(pilotContent)

            let fileExists = fm.fileExists(atPath: outputURL.path)
            let localContent: String?
            if fileExists {
                guard let content = try? String(contentsOf: outputURL, encoding: .utf8) else {
                    result.issues.append("\(target.envFilePath): UTF-8로 읽을 수 없습니다")
                    continue
                }
                localContent = content
            } else {
                localContent = nil
            }
            let localHash = localContent.flatMap(contentHash)

            if fileExists && localHash == nil {
                result.drifts.append(Drift(target: target, outputURL: outputURL, fileExists: true,
                                           fileContent: localContent, reason: .invalid))
                continue
            }

            let baseline = UserDefaults.standard.string(forKey: checkpointKey(target))
            if localHash == pilotHash {
                UserDefaults.standard.set(pilotHash, forKey: checkpointKey(target))
                if fileExists { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path) }
                verifiedTargets += 1
                continue
            }

            // 경로 기반 scope가 아직 없으면 기존 Environment 데이터보다 실제 파일을 우선한다.
            let pilotHasNoValues = variables.allSatisfy { VariableService.value(of: $0).isEmpty }
            if (variables.isEmpty || baseline == nil && pilotHasNoValues),
               let localContent, let localHash, let context,
               adoptLocal(content: localContent, target: target,
                          context: context, existingKeys: Set(variables.map(\.key))) {
                if variables.isEmpty {
                    removeEmptyLegacyPlaceholders(from: target, context: context)
                }
                UserDefaults.standard.set(localHash, forKey: checkpointKey(target))
                result.changed = true
                verifiedTargets += 1
                continue
            }

            // 마지막 파일은 그대로인데 앱 값만 전부 비었다면 자동 덮어쓰지 않는다.
            if pilotHasNoValues, let baseline, baseline == localHash, let localContent,
               EnvParser.parse(localContent).entries.contains(where: { !$0.value.isEmpty }) {
                result.drifts.append(Drift(target: target, outputURL: outputURL,
                                           fileExists: true, fileContent: localContent, reason: .changed))
                continue
            }

            switch decision(baseline: baseline, pilot: pilotHash, local: localHash) {
            case .synced:
                UserDefaults.standard.set(pilotHash, forKey: checkpointKey(target))
                verifiedTargets += 1
            case .writePilot:
                // 발견된 실제 파일이 없는 빈 항목은 만들지 않는다.
                guard !variables.isEmpty || baseline != nil else { continue }
                if let issue = write(pilotContent, to: outputURL, target: target,
                                     safety: safety[target.envFilePath]) {
                    result.issues.append(issue)
                } else {
                    UserDefaults.standard.set(pilotHash, forKey: checkpointKey(target))
                    result.changed = true
                    verifiedTargets += 1
                }
            case .adoptLocal:
                guard let localContent, let localHash, let context,
                      adoptLocal(content: localContent, target: target,
                                 context: context, existingKeys: Set(variables.map(\.key))) else {
                    result.drifts.append(Drift(target: target, outputURL: outputURL,
                                               fileExists: fileExists, fileContent: localContent,
                                               reason: fileExists ? .changed : .deleted))
                    continue
                }
                UserDefaults.standard.set(localHash, forKey: checkpointKey(target))
                result.changed = true
                verifiedTargets += 1
            case .conflict:
                result.drifts.append(Drift(target: target, outputURL: outputURL,
                                           fileExists: fileExists, fileContent: localContent,
                                           reason: fileExists ? .changed : .deleted))
            }
        }
        result.isSynced = !targets.isEmpty && verifiedTargets == targets.count
            && result.drifts.isEmpty && result.issues.isEmpty
        return result
    }

    /// 충돌에서 사용자가 Env Pilot 상태를 선택했을 때 해당 파일만 강제로 적용한다.
    static func forceApply(target: Target, rootURL: URL) -> String? {
        guard let repo = target.repository else { return "Repository를 찾을 수 없습니다" }
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        let variables = (target.variables ?? []).filter {
            $0.environmentName == target.envFilePath && !$0.isIgnored
        }
        guard variables.allSatisfy({ !$0.isSecret || VariableService.valueIfAvailable(of: $0) != nil }) else {
            return "\(target.envFilePath): iCloud Keychain 동기화를 기다리는 Secret이 있습니다"
        }
        let values = Dictionary(uniqueKeysWithValues: variables.map {
            ($0.key, VariableService.valueIfAvailable(of: $0) ?? "")
        })
        let content = EnvParser.serialize(values)
        let outputURL = (target.relativePath == "."
                         ? rootURL
                         : rootURL.appendingPathComponent(target.relativePath))
            .appendingPathComponent(target.outputPath)
        let report = GitSafetyService.check(repo: repo, rootURL: rootURL)
            .first { $0.targetPath == target.envFilePath }
        if let issue = write(content, to: outputURL, target: target, safety: report) {
            return issue
        }
        UserDefaults.standard.set(sha256(content), forKey: checkpointKey(target))
        return nil
    }

    static func sha256(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 주석·정렬·따옴표 차이는 로컬 변경으로 취급하지 않는다.
    static func contentHash(_ content: String) -> String? {
        let parsed = EnvParser.parse(content)
        guard parsed.warnings.isEmpty else { return nil }
        let values = Dictionary(uniqueKeysWithValues: parsed.entries.map { ($0.key, $0.value) })
        return sha256(EnvParser.serialize(values))
    }

    private static func adoptLocal(content: String, target: Target,
                                   context: ModelContext, existingKeys: Set<String>) -> Bool {
        let parsed = EnvParser.parse(content)
        guard parsed.warnings.isEmpty else { return false }
        let fileKeys = Set(parsed.entries.map(\.key))
        guard existingKeys.isSubset(of: fileKeys) else { return false }  // 삭제는 확인 없이는 전파하지 않음
        let scope = target.envFilePath
        let plan = ImportService.plan(content: content, target: target, environmentName: scope)
        do {
            try VariableService.batch("localSync") {
                try ImportService.execute(items: plan.items,
                                          useFileValue: Set(plan.items.map(\.key)),
                                          target: target,
                                          environmentName: scope,
                                          newKeysAreSecret: true,
                                          context: context)
            }
            let verification = ImportService.plan(
                content: content, target: target, environmentName: scope)
            return verification.warnings.isEmpty && verification.items.allSatisfy { item in
                if case .same = item.kind { return true }
                return false
            }
        } catch {
            return false
        }
    }

    private static func write(_ content: String, to outputURL: URL, target: Target,
                              safety: GitSafetyService.Report?) -> String? {
        if let safety, !safety.isIgnored {
            return "\(target.envFilePath): .gitignore에 먼저 추가하세요"
        }
        if let safety, safety.isTracked {
            return "\(target.envFilePath): Git에 tracked 상태입니다"
        }
        do {
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
            return nil
        } catch {
            return "\(target.envFilePath): \(error.localizedDescription)"
        }
    }

    private static func removeEmptyLegacyPlaceholders(from target: Target, context: ModelContext) {
        for variable in (target.variables ?? []) where variable.environmentName != target.envFilePath
            && !variable.isSecret && !variable.isIgnored && variable.value.isEmpty {
            context.delete(variable)
        }
        try? context.save()
    }

    private static func refreshTargets(repo: Repository, rootURL: URL,
                                       context: ModelContext?) -> (targets: [Target], changed: Bool) {
        let discovered = discoverEnvFiles(rootURL: rootURL)
        let existing = repo.targets ?? []
        var used = Set<ObjectIdentifier>()
        var targets: [Target] = []
        var changed = false

        for file in discovered {
            if let target = existing.first(where: {
                !used.contains(ObjectIdentifier($0)) && $0.envFilePath == file.relativePath
            }) {
                used.insert(ObjectIdentifier(target))
                targets.append(target)
                continue
            }

            // 이전 기본 Target이 가리키던 파일이 없으면 같은 폴더의 실제 파일로 전환한다.
            if let target = existing.first(where: { candidate in
                guard !used.contains(ObjectIdentifier(candidate)),
                      candidate.relativePath == file.directoryPath else { return false }
                let oldURL = (candidate.relativePath == "."
                              ? rootURL
                              : rootURL.appendingPathComponent(candidate.relativePath))
                    .appendingPathComponent(candidate.outputPath)
                return !FileManager.default.fileExists(atPath: oldURL.path)
            }) {
                UserDefaults.standard.removeObject(forKey: checkpointKey(target))
                target.outputPath = file.fileName
                used.insert(ObjectIdentifier(target))
                targets.append(target)
                changed = true
                continue
            }

            guard let context else { continue }
            let target = Target(relativePath: file.directoryPath)
            target.outputPath = file.fileName
            target.examplePath = ".env.example"
            target.repository = repo
            context.insert(target)
            used.insert(ObjectIdentifier(target))
            targets.append(target)
            changed = true
        }

        // 값도 실제 파일도 없는 예전 기본 Target은 더 이상 노출하지 않는다.
        for target in existing where !used.contains(ObjectIdentifier(target)) {
            let hasVariables = !(target.variables ?? []).isEmpty
            if !hasVariables, let context {
                UserDefaults.standard.removeObject(forKey: checkpointKey(target))
                context.delete(target)
                changed = true
            } else {
                targets.append(target) // 값이 있는 삭제 파일은 diff로 복구 방향을 선택할 수 있게 유지한다.
            }
        }

        var unique: [String: Target] = [:]
        for target in targets where unique[target.envFilePath] == nil {
            unique[target.envFilePath] = target
        }
        return (unique.values.sorted { $0.envFilePath < $1.envFilePath }, changed)
    }
}

/// Repository 루트 전체를 FSEvents로 재귀 감시하는 watcher.
/// 등록된 target뿐 아니라 새 폴더에 새로 생긴 .env 파일도 감지한다.
final class OutputFileWatcher {
    private var stream: FSEventStreamRef?
    private let rootURL: URL
    private let onChange: () -> Void
    private var hasAccess: Bool

    init(rootURL: URL, onChange: @escaping () -> Void) {
        self.rootURL = rootURL
        self.onChange = onChange
        hasAccess = rootURL.startAccessingSecurityScopedResource()

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0,
                  let paths = Unmanaged<CFArray>.fromOpaque(eventPaths)
                      .takeUnretainedValue() as? [String] else { return }
            // .env* 파일 이벤트만 반응 — node_modules/.git 등 잡음 차단
            let relevant = paths.contains { path in
                !path.contains("/node_modules/") && !path.contains("/.git/")
                    && (path as NSString).lastPathComponent.hasPrefix(".env")
            }
            if relevant {
                Unmanaged<OutputFileWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
            }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,   // 연속 저장 이벤트 병합 (기존 0.2s 디바운스 대체)
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                     | kFSEventStreamCreateFlagUseCFTypes)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if hasAccess {
            rootURL.stopAccessingSecurityScopedResource()
            hasAccess = false
        }
    }

    deinit { stop() }
}
