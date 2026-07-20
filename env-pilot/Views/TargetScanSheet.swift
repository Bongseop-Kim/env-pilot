import SwiftUI
import SwiftData

/// Monorepo 스캔 결과에서 Target을 선택해 생성 (PRD §3.5).
struct TargetScanSheet: View {
    let repo: Repository
    let candidates: [MonorepoScanner.Candidate]   // 기존 Target 제외된 신규 후보만
    let onDone: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>

    init(repo: Repository, candidates: [MonorepoScanner.Candidate], onDone: @escaping () -> Void) {
        self.repo = repo
        self.candidates = candidates
        self.onDone = onDone
        _selected = State(initialValue: Set(candidates.map(\.relativePath)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Monorepo Target 발견")
                .font(.headline)
                .padding()

            List(candidates, id: \.relativePath) { candidate in
                Toggle(isOn: binding(for: candidate.relativePath)) {
                    HStack {
                        Text(candidate.relativePath).fontDesign(.monospaced)
                        Spacer()
                        if candidate.hasExample {
                            Label(".env.example", systemImage: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("취소") { dismiss(); onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("Target 추가 (\(selected.count))") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding()
        }
        .frame(width: 440, height: 340)
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(path) },
            set: { isOn in
                if isOn { selected.insert(path) } else { selected.remove(path) }
            }
        )
    }

    private func add() {
        for candidate in candidates where selected.contains(candidate.relativePath) {
            let target = Target(relativePath: candidate.relativePath)
            target.repository = repo
            context.insert(target)
        }
        try? context.save()
        dismiss()
        onDone()
    }
}
