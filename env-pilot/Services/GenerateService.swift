import Foundation
import SwiftData

/// .env 파일 생성 (PRD §3.4). 플랜 계산 → (UI 확인) → 실행 2단계.
enum GenerateService {

    struct Plan: Identifiable {
        var id: String { targetPath }
        let targetPath: String
        let outputURL: URL
        let content: String
        let existingContent: String?
        let action: Action

        enum Action: Equatable {
            case create        // 파일 없음 → 새로 생성
            case overwrite     // 내용 다름 → 덮어쓰기 (확인 필요)
            case unchanged     // 내용 동일 → 건드리지 않음 (mtime 보존, §3.4)
            case skipEmpty     // 변수 0개 → 스킵 (§3.4)
            case missingDir    // Target 디렉토리 없음
        }
    }

    /// Repository의 모든 Target에 대해 생성 플랜 계산. 파일은 쓰지 않는다.
    static func makePlans(repo: Repository, rootURL: URL, environmentName: String) -> [Plan] {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default

        return (repo.targets ?? [])
            .sorted { $0.relativePath < $1.relativePath }
            .map { target in
                let dir = target.relativePath == "."
                    ? rootURL
                    : rootURL.appendingPathComponent(target.relativePath)
                let outputURL = dir.appendingPathComponent(target.outputPath)

                let variables = (target.variables ?? [])
                    .filter { $0.environmentName == environmentName && !$0.isIgnored }
                let values = Dictionary(uniqueKeysWithValues: variables.map {
                    ($0.key, VariableService.value(of: $0))  // Secret은 Keychain에서 실값 (§3.4)
                })
                let content = EnvParser.serialize(values)
                let existing = try? String(contentsOf: outputURL, encoding: .utf8)

                let action: Plan.Action = if variables.isEmpty {
                    .skipEmpty
                } else if !fm.fileExists(atPath: dir.path) {
                    .missingDir
                } else if existing == nil {
                    .create
                } else if existing == content {
                    .unchanged
                } else {
                    .overwrite
                }

                return Plan(targetPath: target.relativePath, outputURL: outputURL,
                            content: content, existingContent: existing, action: action)
            }
    }

    /// create/overwrite 플랜만 실행. 실패한 플랜의 에러 메시지 목록 반환.
    static func execute(_ plans: [Plan], rootURL: URL) -> [String] {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        var errors: [String] = []
        for plan in plans where plan.action == .create || plan.action == .overwrite {
            do {
                try plan.content.write(to: plan.outputURL, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: plan.outputURL.path)  // §3.11 권한
            } catch {
                errors.append("\(plan.targetPath): \(error.localizedDescription)")
            }
        }
        return errors
    }

    /// 덮어쓰기 확인용 단순 라인 diff (§3.4 미리보기).
    static func lineDiff(old: String, new: String) -> (added: [String], removed: [String]) {
        let oldLines = Set(old.split(separator: "\n").map(String.init))
        let newLines = Set(new.split(separator: "\n").map(String.init))
        return (added: newLines.subtracting(oldLines).sorted(),
                removed: oldLines.subtracting(newLines).sorted())
    }
}
