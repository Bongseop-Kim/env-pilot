import SwiftUI
import SwiftData

/// .env.example diff와 실제 env 파일 변경을 처리한다.
struct GitChangesView: View {
    let diffs: [ExampleDiffService.Diff]
    let drifts: [LocalSyncService.Drift]
    let onChanged: () -> Void
    let onImportDrift: (LocalSyncService.Drift) -> Void
    let onOverwriteDrift: (LocalSyncService.Drift) -> Void
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?
    @State private var pendingDelete: (key: String, target: Target)?

    var body: some View {
        Group {
            if diffs.isEmpty && drifts.isEmpty {
                ContentUnavailableView(
                    "변경 없음 ✓",
                    systemImage: "checkmark.circle",
                    description: Text("실제 env 파일과 Env Pilot 값이 일치합니다")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // 상단 정렬 VStack 안에서 중앙 배치
            } else {
                List {
                    driftSection
                    ForEach(diffs) { diff in
                        Section(diff.target.envFilePath) {
                            ForEach(diff.addedKeys, id: \.self) { key in
                                DiffRow(symbol: "+", color: SeedColor.fgPositive, key: key) {
                                    action("추가") {
                                        try ExampleDiffService.resolveAdded(
                                            key: key, action: .addToFile,
                                            target: diff.target, context: context)
                                    }
                                    action("무시") {
                                        try ExampleDiffService.resolveAdded(
                                            key: key, action: .ignore,
                                            target: diff.target, context: context)
                                    }
                                }
                            }
                            ForEach(diff.removedKeys, id: \.self) { key in
                                DiffRow(symbol: "−", color: SeedColor.fgCritical, key: key) {
                                    Button("삭제", role: .destructive) {
                                        pendingDelete = (key, diff.target)
                                    }
                                    .buttonStyle(.seed(.criticalSolid, size: .xsmall))
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
        .confirmationDialog(
            "'\(pendingDelete?.key ?? "")'를 이 파일에서 삭제할까요?",
            isPresented: Binding(presence: $pendingDelete), titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                guard let pending = pendingDelete else { return }
                do {
                    try ExampleDiffService.resolveRemoved(
                        key: pending.key, action: .deleteFromFile,
                        target: pending.target, context: context)
                    onChanged()
                } catch { errorMessage = error.localizedDescription }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("Secret이면 Keychain 값도 함께 삭제됩니다.")
        }
        .errorAlert($errorMessage)
    }

    /// 외부 수정은 자동 덮어쓰지 않고 사용자가 어느 쪽을 유지할지 선택한다.
    @ViewBuilder private var driftSection: some View {
        if !drifts.isEmpty {
            Section("로컬 .env 변경") {
                ForEach(drifts) { drift in
                    HStack {
                        Image(systemName: "pencil.line").foregroundStyle(SeedColor.fgBrand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drift.target.envFilePath).fontDesign(.monospaced)
                            Text(driftMessage(drift))
                                .font(SeedTypography.body)
                                .foregroundStyle(SeedColor.fgNeutralMuted)
                        }
                        Spacer()
                        if drift.fileExists {
                            Button("로컬 변경 검토") { onImportDrift(drift) }
                                .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                                .help("로컬 파일의 추가·수정 값을 검토")
                        }
                        Button(drift.fileExists ? "Env Pilot 값 적용" : "파일 복원") {
                            onOverwriteDrift(drift)
                        }
                            .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                            .help("Env Pilot의 값으로 실제 파일 갱신")
                    }
                    .seedListRow()
                }
            }
        }
    }

    private func driftMessage(_ drift: LocalSyncService.Drift) -> String {
        switch drift.reason {
        case .changed: "Env Pilot과 파일 내용이 다릅니다"
        case .deleted: "프로젝트에서 파일이 삭제되었습니다"
        case .invalid: "파일 형식을 확인해야 합니다"
        }
    }

    private func action(_ title: String, role: ButtonRole? = nil,
                        _ work: @escaping () throws -> Void) -> some View {
        Button(title, role: role) {
            do { try work(); onChanged() }
            catch { errorMessage = error.localizedDescription }
        }
        .buttonStyle(.seed(.neutralWeak, size: .xsmall))
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
        .seedListRow()
    }
}
