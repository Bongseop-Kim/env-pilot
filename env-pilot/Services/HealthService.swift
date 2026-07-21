import Foundation
import SwiftData
import SwiftUI

/// Health 판정 (PRD §3.8) — 실제 env 파일 단위, example 키 기준.
enum HealthStatus: Int, Comparable {
    case healthy = 0    // 🟢 example의 모든 키(무시 제외)가 값과 함께 존재
    case warning = 1    // 🟡 빈 값 또는 누락 키 존재
    case critical = 2   // 🔴 example에 키가 있는데 해당 실제 파일 scope에 변수가 하나도 없음

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 메뉴바 등 텍스트 전용 컨텍스트용. 뷰에서는 iconName + color 사용.
    var symbol: String {
        switch self {
        case .healthy: "🟢"
        case .warning: "🟡"
        case .critical: "🔴"
        }
    }

    var iconName: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"  // xmark.circle은 닫기 버튼처럼 보여 회피
        }
    }

    // 색상은 프레젠테이션 관심사 — HealthView.swift의 extension(seedTone/color) 참고.
    // (여기 두면 Tests/*Checks.swift의 단독 swiftc 컴파일이 DesignSystem에 묶인다)
}

enum HealthService {
    struct Item: Identifiable {
        let filePath: String
        let missingKeys: [String]
        let emptyValueKeys: [String]
        let status: HealthStatus
        var id: String { filePath }
    }

    /// 같은 폴더에 example 파일이 있는 실제 env 파일만 판정한다.
    static func check(repo: Repository, rootURL: URL) -> [Item] {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }

        var items: [Item] = []
        for target in (repo.targets ?? []).sorted(by: { $0.envFilePath < $1.envFilePath }) {
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

            let variables = allVariables.filter {
                $0.environmentName == target.envFilePath && !$0.isIgnored
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
            items.append(Item(filePath: target.envFilePath, missingKeys: missing,
                              emptyValueKeys: empty, status: status))
        }
        return items
    }

    /// Repository 상태 = 소속 항목 중 최악 값 (§3.8).
    static func overall(_ items: [Item]) -> HealthStatus {
        items.map(\.status).max() ?? .healthy
    }
}
