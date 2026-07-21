import SwiftUI
import SwiftData

/// .env 파일 가져오기 확인 시트 (PRD §3.12) — 충돌 키는 키별 선택.
struct ImportSheet: View {
    let items: [ImportService.Item]
    let warnings: [String]
    let target: Target
    let environmentName: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var useFileValue: Set<String>
    @State private var errorMessage: String?

    init(items: [ImportService.Item], warnings: [String], target: Target, environmentName: String) {
        self.items = items
        self.warnings = warnings
        self.target = target
        self.environmentName = environmentName
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
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import — \(environmentName)")
                .font(SeedTypography.title)
                .padding()

            List(items) { item in
                row(item)
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
                Button("가져오기 (\(applicableCount))") { run() }
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
                Text(item.newValue).foregroundStyle(SeedColor.fgNeutralMuted).fontDesign(.monospaced)
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
                    Text("파일: \(item.newValue)")
                    Text("기존: \(existing)")
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

    private func run() {
        do {
            try ImportService.execute(items: items, useFileValue: useFileValue,
                                      target: target, environmentName: environmentName, context: context)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
