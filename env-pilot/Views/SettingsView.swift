import SwiftUI
import SwiftData

/// 설정 (PRD §4.5) — Workspace 이름, Environment 목록(추가/삭제/순서), 기본 경로 패턴.
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var workspaces: [Workspace]
    @AppStorage("defaultExamplePath") private var defaultExamplePath = ".env.example"
    @AppStorage("defaultOutputPath") private var defaultOutputPath = ".env.local"
    @State private var newEnvironmentName = ""
    @State private var deleteCandidate: EnvEnvironment?
    @State private var deleteMessage = ""

    private var workspace: Workspace? { workspaces.first }
    private var environments: [EnvEnvironment] {
        (workspace?.environments ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Form {
            Section("Workspace") {
                TextField("이름", text: Binding(
                    get: { workspace?.name ?? "" },
                    set: { workspace?.name = $0; try? context.save() }
                ))
            }

            Section("Environments") {
                List {
                    ForEach(environments) { environment in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Text(environment.name)
                            Spacer()
                            Button("삭제", systemImage: "minus.circle") {
                                askDelete(environment)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    .onMove(perform: move)
                }
                HStack {
                    TextField("새 Environment 이름", text: $newEnvironmentName)
                        .onSubmit(add)
                    Button("추가", action: add)
                        .disabled(!canAdd)
                }
            }

            Section("기본 경로") {
                TextField("Example 파일", text: $defaultExamplePath)
                    .fontDesign(.monospaced)
                TextField("Output 파일", text: $defaultOutputPath)
                    .fontDesign(.monospaced)
                Text("새 Target 생성 시 적용됩니다. 기존 Target에는 영향이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
        .confirmationDialog(deleteMessage, isPresented: .constant(deleteCandidate != nil), titleVisibility: .visible) {
            Button("삭제", role: .destructive) { confirmDelete() }
            Button("취소", role: .cancel) { deleteCandidate = nil }
        }
    }

    private var canAdd: Bool {
        let name = newEnvironmentName.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !environments.contains { $0.name == name }
    }

    private func add() {
        guard canAdd, let workspace else { return }
        let environment = EnvEnvironment(
            name: newEnvironmentName.trimmingCharacters(in: .whitespaces),
            sortOrder: (environments.last?.sortOrder ?? -1) + 1
        )
        environment.workspace = workspace
        context.insert(environment)
        try? context.save()
        newEnvironmentName = ""
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = environments
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, environment) in ordered.enumerated() {
            environment.sortOrder = index
        }
        try? context.save()
    }

    private func askDelete(_ environment: EnvEnvironment) {
        let name = environment.name
        let count = (try? context.fetchCount(FetchDescriptor<Variable>(
            predicate: #Predicate { $0.environmentName == name }
        ))) ?? 0
        deleteMessage = count > 0
            ? "\"\(name)\" Environment를 삭제할까요? 이 환경의 변수 \(count)개가 보이지 않게 됩니다."
            : "\"\(name)\" Environment를 삭제할까요?"
        deleteCandidate = environment
    }

    private func confirmDelete() {
        if let environment = deleteCandidate {
            context.delete(environment)
            try? context.save()
        }
        deleteCandidate = nil
    }
}
