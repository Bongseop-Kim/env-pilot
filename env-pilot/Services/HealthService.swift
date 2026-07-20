import Foundation
import SwiftData

/// Health 판정 (PRD §3.8) — Target × Environment 단위, example 키 기준.
enum HealthStatus: Int, Comparable {
    case healthy = 0    // 🟢 example의 모든 키(무시 제외)가 값과 함께 존재
    case warning = 1    // 🟡 빈 값 또는 누락 키 존재
    case critical = 2   // 🔴 example에 키가 있는데 해당 Environment에 변수가 하나도 없음

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var symbol: String {
        switch self {
        case .healthy: "🟢"
        case .warning: "🟡"
        case .critical: "🔴"
        }
    }
}

enum HealthService {
    struct Item: Identifiable {
        let targetPath: String
        let environmentName: String
        let missingKeys: [String]
        let emptyValueKeys: [String]
        let status: HealthStatus
        var id: String { "\(targetPath)|\(environmentName)" }
    }

    /// example 파일이 있는 Target만 판정 대상 (기준이 example 키이므로).
    static func check(repo: Repository, rootURL: URL, environmentNames: [String]) -> [Item] {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        var items: [Item] = []
        for target in (repo.targets ?? []).sorted(by: { $0.relativePath < $1.relativePath }) {
            let dir = target.relativePath == "."
                ? rootURL
                : rootURL.appendingPathComponent(target.relativePath)
            guard let content = try? String(
                contentsOf: dir.appendingPathComponent(target.examplePath), encoding: .utf8
            ) else { continue }

            let allVariables = target.variables ?? []
            let ignoredKeys = Set(allVariables.filter(\.isIgnored).map(\.key))
            let exampleKeys = ExampleDiffService.keys(of: content).subtracting(ignoredKeys)
            guard !exampleKeys.isEmpty else { continue }

            for environmentName in environmentNames {
                let variables = allVariables.filter {
                    $0.environmentName == environmentName && !$0.isIgnored
                }
                let variableKeys = Set(variables.map(\.key))
                let missing = exampleKeys.subtracting(variableKeys).sorted()
                let empty = variables
                    .filter { exampleKeys.contains($0.key) && VariableService.value(of: $0).isEmpty }
                    .map(\.key).sorted()

                let status: HealthStatus = if variables.isEmpty {
                    .critical
                } else if missing.isEmpty && empty.isEmpty {
                    .healthy
                } else {
                    .warning
                }
                items.append(Item(targetPath: target.relativePath, environmentName: environmentName,
                                  missingKeys: missing, emptyValueKeys: empty, status: status))
            }
        }
        return items
    }

    /// Repository 상태 = 소속 항목 중 최악 값 (§3.8).
    static func overall(_ items: [Item]) -> HealthStatus {
        items.map(\.status).max() ?? .healthy
    }
}
