import SwiftUI
import SwiftData

/// Monorepo 스캔 결과에서 Target을 선택해 생성 (PRD §3.5).
/// 이미 등록된 경로도 "추가됨"으로 표시해 무엇이 탐지됐는지 보여준다.
struct TargetScanSheet: View {
    let repo: Repository
    let candidates: [MonorepoScanner.Candidate]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var saveError: String?
    private let existingPaths: Set<String>

    init(repo: Repository, candidates: [MonorepoScanner.Candidate]) {
        self.repo = repo
        self.candidates = candidates
        let existing = Set((repo.targets ?? []).map(\.relativePath))
        existingPaths = existing
        _selected = State(initialValue: Set(candidates.map(\.relativePath)).subtracting(existing))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Monorepo Target 발견")
                .font(SeedTypography.title)
                .padding()

            List(candidates, id: \.relativePath) { candidate in
                let isExisting = existingPaths.contains(candidate.relativePath)
                Toggle(isOn: isExisting ? .constant(true) : binding(for: candidate.relativePath)) {
                    HStack {
                        Text(candidate.relativePath == "." ? ". (Root)" : candidate.relativePath)
                            .fontDesign(.monospaced)
                        Spacer()
                        if candidate.hasExample {
                            Label(".env.example", systemImage: "doc.text")
                                .font(SeedTypography.body)
                                .foregroundStyle(SeedColor.fgNeutralMuted)
                        }
                        if isExisting {
                            Text("추가됨").font(SeedTypography.body).foregroundStyle(SeedColor.fgNeutralMuted)
                        }
                    }
                }
                .disabled(isExisting)
                .toggleStyle(.seed)
                .seedListRow()
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .buttonStyle(.seed(.neutralWeak, size: .small))
                    .keyboardShortcut(.cancelAction)
                Button("Target 추가 (\(selected.count))") { add() }
                    .buttonStyle(.seed(.brandSolid, size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding()
        }
        .frame(width: 440, height: 340)
        .errorAlert($saveError, title: "저장 실패")
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
        for candidate in candidates
        where selected.contains(candidate.relativePath) && !existingPaths.contains(candidate.relativePath) {
            let target = Target.makeWithDefaults(relativePath: candidate.relativePath)
            target.repository = repo
            context.insert(target)
        }
        do {
            try context.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
