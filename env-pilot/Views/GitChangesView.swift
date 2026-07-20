import SwiftUI
import SwiftData

/// .env.example diff 처리 탭 (PRD §3.7) — 키별 추가/삭제/무시.
struct GitChangesView: View {
    let diffs: [ExampleDiffService.Diff]
    let environmentNames: [String]
    let onChanged: () -> Void
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if diffs.isEmpty {
                ContentUnavailableView(
                    "변경 없음 ✓",
                    systemImage: "checkmark.circle",
                    description: Text(".env.example이 마지막 확인 시점과 일치합니다")
                )
            } else {
                List {
                    ForEach(diffs) { diff in
                        Section(diff.target.relativePath) {
                            ForEach(diff.addedKeys, id: \.self) { key in
                                DiffRow(symbol: "+", color: .green, key: key) {
                                    action("추가") {
                                        try ExampleDiffService.resolveAdded(
                                            key: key, action: .addToAllEnvironments, target: diff.target,
                                            environmentNames: environmentNames, context: context)
                                    }
                                    action("무시") {
                                        try ExampleDiffService.resolveAdded(
                                            key: key, action: .ignore, target: diff.target,
                                            environmentNames: environmentNames, context: context)
                                    }
                                }
                            }
                            ForEach(diff.removedKeys, id: \.self) { key in
                                DiffRow(symbol: "−", color: .red, key: key) {
                                    action("삭제", role: .destructive) {
                                        try ExampleDiffService.resolveRemoved(
                                            key: key, action: .deleteFromAllEnvironments,
                                            target: diff.target, context: context)
                                    }
                                    action("무시") {
                                        try ExampleDiffService.resolveRemoved(
                                            key: key, action: .ignore, target: diff.target, context: context)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .alert("오류", isPresented: .constant(errorMessage != nil)) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func action(_ title: String, role: ButtonRole? = nil,
                        _ work: @escaping () throws -> Void) -> some View {
        Button(title, role: role) {
            do { try work(); onChanged() }
            catch { errorMessage = error.localizedDescription }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct DiffRow<Actions: View>: View {
    let symbol: String
    let color: Color
    let key: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack {
            Text(symbol).foregroundStyle(color).fontWeight(.bold)
            Text(key).fontDesign(.monospaced)
            Spacer()
            actions
        }
        .padding(.vertical, 2)
    }
}
