import SwiftUI
import SwiftData

/// 로컬 .env 변경 검토 — 충돌 키는 키별 선택.
struct ImportSheet: View {
    let items: [ImportService.Item]
    let warnings: [String]
    let target: Target
    let newKeysAreSecret: Bool
    let missingVariables: [Variable]
    let onImported: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var useFileValue: Set<String>
    @State private var deleteKeys: Set<String> = []
    @State private var errorMessage: String?

    init(items: [ImportService.Item], warnings: [String], target: Target,
         newKeysAreSecret: Bool = false, missingVariables: [Variable] = [],
         onImported: @escaping () -> Void = {}) {
        self.items = items
        self.warnings = warnings
        self.target = target
        self.newKeysAreSecret = newKeysAreSecret
        self.missingVariables = missingVariables
        self.onImported = onImported
        // 기본: 파일 값 사용 (§3.12)
        _useFileValue = State(initialValue: Set(items.compactMap {
            if case .conflict = $0.kind { $0.key } else { nil }
        }))
    }

    private var applicableCount: Int {
        items.filter {
            switch $0.kind {
            case .add: true
            case .conflict: useFileValue.contains($0.key)
            case .same: false
            }
        }.count + deleteKeys.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("로컬 변경 검토 — \(target.envFilePath)")
                .font(SeedTypography.title)
                .padding()

            List {
                ForEach(items) { item in row(item) }
                if !missingVariables.isEmpty {
                    Section("로컬 파일에서 삭제됨") {
                        ForEach(missingVariables) { variable in
                            HStack {
                                Image(systemName: "minus.circle.fill").foregroundStyle(SeedColor.fgCritical)
                                Text(variable.key).fontDesign(.monospaced)
                                Spacer()
                                SeedSegmentedControl(selection: deleteBinding(variable.key),
                                                     items: [(true, "로컬 삭제 반영"),
                                                             (false, "기존 값 유지")])
                                    .fixedSize()
                            }
                        }
                    }
                }
            }

            if !warnings.isEmpty {
                SeedCallout(warnings.joined(separator: " / "), tone: .warning)
                    .padding(.horizontal)
            }
            if let errorMessage {
                SeedCallout(errorMessage, tone: .critical)
                    .padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .buttonStyle(.seed(.neutralWeak, size: .small))
                    .keyboardShortcut(.cancelAction)
                Button("적용 (\(applicableCount))") { run() }
                    .buttonStyle(.seed(.brandSolid, size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(applicableCount == 0)
            }
            .padding()
        }
        .frame(width: 520, height: 400)
    }

    @ViewBuilder private func row(_ item: ImportService.Item) -> some View {
        switch item.kind {
        case .add:
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(SeedColor.fgPositive)
                Text(item.key).fontDesign(.monospaced)
                Spacer()
                Text(displayValue(item.newValue, key: item.key))
                    .foregroundStyle(SeedColor.fgNeutralMuted).fontDesign(.monospaced)
                    .lineLimit(1).truncationMode(.middle)
            }
        case .same:
            HStack {
                Image(systemName: "equal.circle").foregroundStyle(SeedColor.fgNeutralMuted)
                Text(item.key).fontDesign(.monospaced).foregroundStyle(SeedColor.fgNeutralMuted)
                Spacer()
                Text("동일 — 스킵").font(SeedTypography.body).foregroundStyle(SeedColor.fgNeutralMuted)
            }
        case .conflict(let existing):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(SeedColor.fgBrand)
                    Text(item.key).fontDesign(.monospaced).fontWeight(.medium)
                    Spacer()
                    SeedSegmentedControl(selection: choiceBinding(item.key),
                                         items: [(true, "파일 값 사용"), (false, "기존 값 유지")])
                        .fixedSize()
                }
                Group {
                    Text("파일: \(displayValue(item.newValue, key: item.key))")
                    Text("기존: \(displayValue(existing, key: item.key))")
                }
                .font(SeedTypography.body).fontDesign(.monospaced).foregroundStyle(SeedColor.fgNeutralMuted)
                .lineLimit(1).truncationMode(.middle)
                .padding(.leading, 24)
            }
        }
    }

    private func choiceBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { useFileValue.contains(key) },
            set: { useFile in
                if useFile { useFileValue.insert(key) } else { useFileValue.remove(key) }
            }
        )
    }

    private func displayValue(_ value: String, key: String) -> String {
        let existing = (target.variables ?? []).first {
            $0.key == key && $0.environmentName == target.envFilePath
        }
        return existing?.isSecret == true || (existing == nil && newKeysAreSecret) ? "••••••••" : value
    }

    private func deleteBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { deleteKeys.contains(key) },
            set: { shouldDelete in
                if shouldDelete { deleteKeys.insert(key) } else { deleteKeys.remove(key) }
            }
        )
    }

    private func run() {
        do {
            try ImportService.execute(items: items, useFileValue: useFileValue,
                                      target: target, environmentName: target.envFilePath,
                                      newKeysAreSecret: newKeysAreSecret, context: context)
            for variable in missingVariables where deleteKeys.contains(variable.key) {
                try VariableService.delete(variable, context: context)
            }
            onImported()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
