import Foundation
import SwiftData

/// 기존 .env 파일 가져오기 (PRD §3.12).
enum ImportService {

    struct Item: Identifiable {
        let key: String
        let newValue: String
        let kind: Kind
        var id: String { key }

        enum Kind: Equatable {
            case add                        // 신규 키
            case conflict(existing: String) // 값 다름 — 키별 선택 (기본: 파일 값)
            case same                       // 값 동일 — 조용히 스킵 (§3.12)
        }
    }

    static func plan(content: String, target: Target, environmentName: String) -> (items: [Item], warnings: [String]) {
        let parsed = EnvParser.parse(content)
        let items = parsed.entries.map { entry in
            let existing = (target.variables ?? []).first {
                $0.key == entry.key && $0.environmentName == environmentName && !$0.isIgnored
            }
            let kind: Item.Kind = if let existing {
                VariableService.value(of: existing) == entry.value
                    ? .same
                    : .conflict(existing: VariableService.value(of: existing))
            } else {
                .add
            }
            return Item(key: entry.key, newValue: entry.value, kind: kind)
        }
        return (items, parsed.warnings)
    }

    /// useFileValue: conflict 키 중 "파일 값 사용"을 선택한 키 집합.
    static func execute(items: [Item], useFileValue: Set<String>, target: Target,
                        environmentName: String, newKeysAreSecret: Bool = false,
                        context: ModelContext) throws {
        try VariableService.batch("fileImport") {
            for item in items {
                switch item.kind {
                case .add:
                    // 무시 마커가 있던 키면 마커를 실제 변수로 되살린다
                    if let marker = (target.variables ?? []).first(where: {
                        $0.key == item.key && $0.environmentName == environmentName && $0.isIgnored
                    }) {
                        marker.isIgnored = false
                        if newKeysAreSecret {
                            try VariableService.setSecret(marker, true, context: context)
                        }
                        try VariableService.updateValue(marker, to: item.newValue, context: context)
                    } else {
                        try VariableService.create(key: item.key, value: item.newValue,
                                                   isSecret: newKeysAreSecret,
                                                   environmentName: environmentName, target: target, context: context)
                    }
                case .conflict where useFileValue.contains(item.key):
                    if let variable = (target.variables ?? []).first(where: {
                        $0.key == item.key && $0.environmentName == environmentName && !$0.isIgnored
                    }) {
                        try VariableService.updateValue(variable, to: item.newValue, context: context)
                    }
                default:
                    break
                }
            }
        }
        try context.save()
    }
}
