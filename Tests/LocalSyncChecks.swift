// 실제 .env 경로 ↔ Env Pilot 자동 동기화 검증.
// 실행: swiftc -parse-as-library env-pilot/Models/Models.swift env-pilot/Services/EnvParser.swift \
//       env-pilot/Services/GitInfo.swift env-pilot/Services/GitSafetyService.swift \
//       env-pilot/Services/SecretStore.swift env-pilot/Services/VariableService.swift \
//       env-pilot/Services/ImportService.swift env-pilot/Services/LocalSyncService.swift \
//       Tests/LocalSyncChecks.swift -o /tmp/local-sync-check && /tmp/local-sync-check

import Foundation
import SwiftData

@main
struct LocalSyncChecks {
    static func main() throws {
        assert(LocalSyncService.decision(baseline: "A", pilot: "B", local: "A") == .writePilot)
        assert(LocalSyncService.decision(baseline: "A", pilot: "A", local: "B") == .adoptLocal)
        assert(LocalSyncService.decision(baseline: "A", pilot: "B", local: "C") == .conflict)
        assert(LocalSyncService.decision(baseline: nil, pilot: "A", local: nil) == .writePilot)
        assert(LocalSyncService.contentHash("# comment\nB=2\nA=1\n")
               == LocalSyncService.contentHash("A=1\nB=2\n"), "주석·정렬 차이 무시")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "local-sync-check-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let container = try ModelContainer(
            for: Schema([Workspace.self, HistoryEntry.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        // 실제 값 파일은 경로별로 찾고 example·의존성 폴더는 제외한다.
        try "ROOT=one\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "LOCAL=two\n".write(to: root.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        try "TEMPLATE=\n".write(to: root.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
        try "TEMPLATE=\n".write(to: root.appendingPathComponent(".env.test.example"),
                                 atomically: true, encoding: .utf8)
        let api = root.appendingPathComponent("apps/api")
        try fm.createDirectory(at: api, withIntermediateDirectories: true)
        try "API=three\n".write(to: api.appendingPathComponent(".env.production"),
                                atomically: true, encoding: .utf8)
        let dependency = root.appendingPathComponent("node_modules/pkg")
        try fm.createDirectory(at: dependency, withIntermediateDirectories: true)
        try "IGNORED=yes\n".write(to: dependency.appendingPathComponent(".env"),
                                  atomically: true, encoding: .utf8)

        let discovered = LocalSyncService.discoverEnvFiles(rootURL: root).map(\.relativePath)
        assert(discovered == [".env", ".env.local", "apps/api/.env.production"],
               "실제 env 파일 경로 탐색 (got \(discovered))")

        let repo = Repository(name: "paths")
        context.insert(repo)
        try context.save()
        defer { LocalSyncService.clearLocalState(for: repo) }

        var result = LocalSyncService.reconcile(repo: repo, rootURL: root, context: context)
        let targets = (repo.targets ?? []).sorted { $0.envFilePath < $1.envFilePath }
        assert(result.isSynced && result.drifts.isEmpty, "최초 실제 파일 가져오기")
        assert(targets.map(\.envFilePath) == discovered, "파일 경로가 관리 단위")

        func variable(_ key: String, in file: String) -> Variable? {
            targets.first { $0.envFilePath == file }?.variables?.first {
                $0.key == key && $0.environmentName == file && !$0.isIgnored
            }
        }
        guard let rootVariable = variable("ROOT", in: ".env") else {
            assertionFailure(".env의 ROOT 키를 가져와야 함")
            return
        }
        assert(VariableService.value(of: rootVariable) == "one", ".env 실제 값 보존")
        assert(VariableService.value(of: variable("LOCAL", in: ".env.local")!) == "two",
               ".env.local은 별도 실제 파일로 관리")
        assert(VariableService.value(of: variable("API", in: "apps/api/.env.production")!) == "three",
               "중첩 실제 경로 값 보존")

        // 앱만 수정되면 선택 파일 하나에만 반영한다.
        try VariableService.updateValue(rootVariable, to: "pilot", context: context)
        result = LocalSyncService.reconcile(repo: repo, rootURL: root, context: context)
        let rootAfterPilot = try String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)
        let localAfterPilot = try String(contentsOf: root.appendingPathComponent(".env.local"), encoding: .utf8)
        assert(result.isSynced, "앱 단독 변경 자동 반영")
        assert(rootAfterPilot == "ROOT=pilot\n", "선택 파일에 Env Pilot 값 적용")
        assert(localAfterPilot == "LOCAL=two\n", "다른 실제 파일은 변경하지 않음")

        // 로컬만 수정되면 해당 경로 scope로 가져온다.
        try "ROOT=local\nNEW_SECRET=value\n".write(
            to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        result = LocalSyncService.reconcile(repo: repo, rootURL: root, context: context)
        let newSecret = variable("NEW_SECRET", in: ".env")!
        assert(result.isSynced && VariableService.value(of: rootVariable) == "local", "로컬 수정 자동 반영")
        assert(newSecret.isSecret && VariableService.value(of: newSecret) == "value", "새 로컬 키는 Secret")

        // 양쪽이 기준점 이후 바뀌면 diff로 남기고 어느 쪽도 자동 덮어쓰지 않는다.
        try "ROOT=file-change\nNEW_SECRET=value\n".write(
            to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try VariableService.updateValue(rootVariable, to: "pilot-change", context: context)
        result = LocalSyncService.reconcile(repo: repo, rootURL: root, context: context)
        let rootDuringConflict = try String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)
        assert(!result.isSynced && result.drifts.map(\.target.envFilePath) == [".env"],
               "실제 diff가 있는 파일만 동기화 필요")
        assert(rootDuringConflict.contains("ROOT=file-change"), "충돌 시 실제 파일 보존")
        assert(LocalSyncService.forceApply(target: rootVariable.target!, rootURL: root) == nil,
               "사용자가 Env Pilot 방향 선택 가능")

        // 실제 파일 삭제도 diff이며 명시적으로 복원할 수 있다.
        try fm.removeItem(at: root.appendingPathComponent(".env"))
        result = LocalSyncService.reconcile(repo: repo, rootURL: root, context: context)
        assert(!result.isSynced && result.drifts.contains {
            $0.target.envFilePath == ".env" && $0.reason == .deleted
        }, "파일 삭제 diff")
        assert(LocalSyncService.forceApply(target: rootVariable.target!, rootURL: root) == nil,
               "삭제 파일 복원")

        // 예전 기본 .env.local Target은 실제 .env가 있으면 그 경로로 전환하고 실제 값을 우선한다.
        let legacyRoot = root.appendingPathComponent("legacy")
        try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try "FROM_DOT_ENV=yes\n".write(to: legacyRoot.appendingPathComponent(".env"),
                                        atomically: true, encoding: .utf8)
        let legacyRepo = Repository(name: "legacy")
        context.insert(legacyRepo)
        let legacyTarget = Target(relativePath: ".")
        legacyTarget.repository = legacyRepo
        context.insert(legacyTarget)
        _ = try VariableService.create(key: "FROM_DOT_ENV", value: "", environmentName: "Local",
                                       target: legacyTarget, context: context)
        defer { LocalSyncService.clearLocalState(for: legacyRepo) }

        let legacyResult = LocalSyncService.reconcile(
            repo: legacyRepo, rootURL: legacyRoot, context: context)
        let migrated = (legacyTarget.variables ?? []).first {
            $0.key == "FROM_DOT_ENV" && $0.environmentName == ".env"
        }
        assert(legacyResult.isSynced && legacyTarget.envFilePath == ".env", "기존 Target을 실제 경로로 전환")
        assert(migrated.map { VariableService.value(of: $0) } == "yes", "기존 빈값보다 실제 .env 값 우선")
        assert(!(legacyTarget.variables ?? []).contains { $0.environmentName == "Local" },
               "구버전 빈 placeholder 정리")
        assert(!fm.fileExists(atPath: legacyRoot.appendingPathComponent(".env.local").path),
               ".env.local을 임의 생성하지 않음")

        // 실제 파일도 값도 없으면 아무 경로나 빈 파일을 만들지 않는다.
        let emptyRoot = root.appendingPathComponent("empty")
        try fm.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let emptyRepo = Repository(name: "empty")
        context.insert(emptyRepo)
        let emptyTarget = Target(relativePath: ".")
        emptyTarget.repository = emptyRepo
        context.insert(emptyTarget)
        try context.save()
        let emptyResult = LocalSyncService.reconcile(repo: emptyRepo, rootURL: emptyRoot, context: context)
        assert(!emptyResult.isSynced && (emptyRepo.targets ?? []).isEmpty,
               "실제 env 파일이 없으면 관리 항목 없음")
        assert(!fm.fileExists(atPath: emptyRoot.appendingPathComponent(".env.local").path),
               "기본 파일 자동 생성 안 함")

        // 기존 파일을 직접 덮어쓰는 저장도 watcher가 감지한다.
        var watcherDetectedChange = false
        let watcher = OutputFileWatcher(rootURL: root, targets: [rootVariable.target!]) {
            watcherDetectedChange = true
        }
        let outputURL = root.appendingPathComponent(".env")
        let handle = try FileHandle(forWritingTo: outputURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("ROOT=watched\nNEW_SECRET=value\n".utf8))
        try handle.close()
        let deadline = Date().addingTimeInterval(2)
        while !watcherDetectedChange && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        watcher.stop()
        assert(watcherDetectedChange, "실제 env 파일 직접 수정 감지")

        // 테스트가 만든 Keychain 값을 정리한다.
        for target in [targets, [legacyTarget]].flatMap({ $0 }) {
            for variable in target.variables ?? [] where variable.isSecret {
                try? VariableService.delete(variable, context: context)
            }
        }
        print("✅ LocalSync: all checks passed")
    }
}
