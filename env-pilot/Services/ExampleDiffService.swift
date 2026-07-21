import Foundation
import SwiftData

/// .env.example 변경 감지와 처리 (PRD §3.6, §3.7).
/// 키 존재 여부만 비교한다 (example 특성상 값 변경은 추적 안 함).
enum ExampleDiffService {

    struct Diff: Identifiable {
        let target: Target
        let addedKeys: [String]
        let removedKeys: [String]
        var id: String { target.envFilePath }
        var count: Int { addedKeys.count + removedKeys.count }
    }

    enum AddedAction { case addToFile, ignore }
    enum RemovedAction { case deleteFromFile, ignore }

    /// 모든 Target의 example을 스냅샷과 비교. 스냅샷 없는 최초 스캔은 저장만 하고 diff를 만들지 않는다 (§3.6).
    static func scan(repo: Repository, rootURL: URL, context: ModelContext) -> [Diff] {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        var diffs: [Diff] = []
        for target in (repo.targets ?? []).sorted(by: { $0.relativePath < $1.relativePath }) {
            let dir = target.relativePath == "."
                ? rootURL
                : rootURL.appendingPathComponent(target.relativePath)
            guard let content = try? String(
                contentsOf: dir.appendingPathComponent(target.examplePath), encoding: .utf8
            ) else { continue }   // example 파일 없으면 스킵

            guard let snapshot = target.exampleSnapshot else {
                target.exampleSnapshot = content
                continue
            }
            let currentKeys = keys(of: content)
            let snapshotKeys = keys(of: snapshot)
            let added = currentKeys.subtracting(snapshotKeys).sorted()
            let removed = snapshotKeys.subtracting(currentKeys).sorted()
            if !added.isEmpty || !removed.isEmpty {
                diffs.append(Diff(target: target, addedKeys: added, removedKeys: removed))
            }
        }
        try? context.save()
        return diffs
    }

    static func keys(of content: String) -> Set<String> {
        Set(EnvParser.parse(content).entries.map(\.key))
    }

    /// 추가된 키 처리: 해당 실제 env 파일에 빈 값 생성 또는 무시 마커 (§3.7).
    static func resolveAdded(key: String, action: AddedAction, target: Target,
                             context: ModelContext) throws {
        let scope = target.envFilePath
        let exists = (target.variables ?? []).contains {
            $0.key == key && $0.environmentName == scope
        }
        if !exists {
            switch action {
            case .addToFile:
                try VariableService.create(key: key, value: "", environmentName: scope,
                                           target: target, context: context)
            case .ignore:
                // 무시 마커 — Health(§3.8)가 "무시 키 제외" 판정에 사용. History 기록 없음.
                let marker = Variable(key: key, value: "", environmentName: scope)
                marker.isIgnored = true
                marker.target = target
                context.insert(marker)
            }
        }
        appendToSnapshot(key: key, target: target)
        try context.save()
    }

    /// 삭제된 키 처리: 해당 실제 env 파일에서 삭제 또는 무시 (§3.7).
    static func resolveRemoved(key: String, action: RemovedAction, target: Target,
                               context: ModelContext) throws {
        if action == .deleteFromFile {
            for variable in (target.variables ?? []).filter({
                $0.key == key && $0.environmentName == target.envFilePath
            }) {
                try VariableService.delete(variable, context: context)
            }
        }
        removeFromSnapshot(key: key, target: target)
        try context.save()
    }

    // MARK: - example 역생성 (§3.17)

    /// Variables로부터 example 내용 생성 — 선택 파일의 키(무시 키 제외), 값은 빈 문자열,
    /// note가 있으면 위 줄에 주석. 키 정렬·`KEY=` 형식은 §3.2 직렬화와 동일.
    static func exampleContent(for target: Target) -> String {
        let variables = (target.variables ?? []).filter {
            $0.environmentName == target.envFilePath && !$0.isIgnored
        }
        var noteByKey: [String: String] = [:]
        for variable in variables where noteByKey[variable.key] == nil {
            if let note = variable.note, !note.isEmpty { noteByKey[variable.key] = note }
        }
        var lines: [String] = []
        for key in Set(variables.map(\.key)).sorted() {
            if let note = noteByKey[key] { lines.append("# \(note)") }
            lines.append("\(key)=")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// example 파일 쓰기 + 스냅샷 갱신 — 자기 변경이 §3.6 diff로 뜨지 않도록.
    static func writeExample(content: String, target: Target, rootURL: URL) throws {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        let dir = target.relativePath == "."
            ? rootURL
            : rootURL.appendingPathComponent(target.relativePath)
        try content.write(to: dir.appendingPathComponent(target.examplePath),
                          atomically: true, encoding: .utf8)
        target.exampleSnapshot = content
    }

    // 처리된 키는 스냅샷에 반영해 같은 diff가 다시 나타나지 않게 한다 (§3.7 수용 기준).
    private static func appendToSnapshot(key: String, target: Target) {
        target.exampleSnapshot = (target.exampleSnapshot ?? "") + "\n\(key)="
    }

    private static func removeFromSnapshot(key: String, target: Target) {
        guard let snapshot = target.exampleSnapshot else { return }
        target.exampleSnapshot = snapshot
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { EnvParser.parse(String($0)).entries.first?.key != key }
            .joined(separator: "\n")
    }
}
