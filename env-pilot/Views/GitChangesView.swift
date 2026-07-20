import SwiftUI
import SwiftData

/// .env.example diff 처리 탭 (PRD §3.7) — 키별 추가/삭제/무시. + Output Drift (§3.18).
struct GitChangesView: View {
    let diffs: [ExampleDiffService.Diff]
    let drifts: [GenerateService.Drift]
    let environmentNames: [String]
    let onChanged: () -> Void
    let onImportDrift: (GenerateService.Drift) -> Void
    let onOverwriteDrift: (GenerateService.Drift) -> Void
    let onIgnoreDrift: (GenerateService.Drift) -> Void
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if diffs.isEmpty && drifts.isEmpty {
                ContentUnavailableView(
                    "변경 없음 ✓",
                    systemImage: "checkmark.circle",
                    description: Text(".env.example과 출력 파일이 마지막 확인 시점과 일치합니다")
                )
            } else {
                List {
                    driftSection
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

    /// §3.18 — 외부에서 수정된 출력 파일: 가져오기 / 덮어쓰기 / 무시. 삭제된 파일은 덮어쓰기만.
    @ViewBuilder private var driftSection: some View {
        if !drifts.isEmpty {
            Section("외부에서 수정됨") {
                ForEach(drifts) { drift in
                    HStack {
                        Image(systemName: "pencil.line").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drift.outputURL.lastPathComponent).fontDesign(.monospaced)
                            Text(drift.fileExists
                                 ? "\(drift.target.relativePath) — Generate 이후 파일이 앱 밖에서 수정되었습니다"
                                 : "\(drift.target.relativePath) — 파일이 삭제되었습니다")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if drift.fileExists {
                            Button("가져오기") { onImportDrift(drift) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("파일 내용을 앱으로 가져오기")
                            Button("무시") { onIgnoreDrift(drift) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .help("현재 파일 내용을 새 기준점으로 인정")
                        }
                        Button("덮어쓰기") { onOverwriteDrift(drift) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help("앱에 저장된 변수로 파일을 다시 생성")
                    }
                    .padding(.vertical, 2)
                }
            }
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
