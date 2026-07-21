import SwiftUI
import SwiftData
import ServiceManagement

/// 설정 (PRD §4.5) — Workspace 이름, 기본 경로 패턴, 로그인 시 시작(§3.15).
/// Environment 목록은 Repository별 관리 — 툴바 Environment 셀렉터 옆 편집 버튼(EnvironmentsEditor).
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var workspaces: [Workspace]
    @AppStorage("defaultExamplePath") private var defaultExamplePath = ".env.example"
    @AppStorage("defaultOutputPath") private var defaultOutputPath = ".env.local"
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage(BiometricGate.settingKey) private var requireAuthForSecrets = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var workspace: Workspace? { workspaces.first }

    var body: some View {
        Form {
            Section("Workspace") {
                TextField("이름", text: Binding(
                    get: { workspace?.name ?? "" },
                    set: { workspace?.name = $0; try? context.save() }
                ))
            }

            Section("일반") {
                // §3.15 — 상태의 소스는 SMAppService.status (별도 저장 안 함).
                // 시스템 설정에서 직접 끈 경우 창을 다시 열면 반영된다.
                Toggle("로그인 시 시작", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                    .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
                Toggle("Secret 표시·복사 시 인증 요구", isOn: $requireAuthForSecrets)
                Text("Touch ID 또는 로그인 비밀번호로 승인합니다. 승인 후 60초간 재인증을 생략합니다.")
                    .font(.caption)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
            }

            Section("동기화") {
                Toggle("iCloud 동기화", isOn: $iCloudSyncEnabled)
                Text("같은 Apple 계정의 Mac 간에 데이터가 동기화됩니다. Secret은 iCloud Keychain으로 별도 동기화되며, 로컬 폴더 경로는 Mac마다 다시 연결해야 합니다. 변경은 앱을 다시 실행하면 적용됩니다.")
                    .font(.caption)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
            }

            Section("기본 경로") {
                TextField("Example 파일", text: $defaultExamplePath)
                    .fontDesign(.monospaced)
                TextField("Output 파일", text: $defaultOutputPath)
                    .fontDesign(.monospaced)
                Text("새 Target 생성 시 적용됩니다. 기존 Target에는 영향이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.seed)
        .frame(width: 480, height: 440)
    }
}

/// 선택된 Repository의 Environment 목록 편집 — 툴바 Environment 셀렉터 옆 버튼에서 시트로 표시.
struct EnvironmentsEditor: View {
    let repo: Repository
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var newEnvironmentName = ""
    @State private var deleteCandidate: EnvEnvironment?
    @State private var deleteMessage = ""

    private var environments: [EnvEnvironment] {
        (repo.environments ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Form {
            Section("\(repo.name) — Environments") {
                List {
                    ForEach(environments) { environment in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(SeedColor.fgNeutralSubtle)
                            Text(environment.name)
                            Spacer()
                            Button("삭제", systemImage: "trash") {
                                askDelete(environment)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.seedIcon())
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
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 300)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("완료") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
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
        guard canAdd else { return }
        let environment = EnvEnvironment(
            name: newEnvironmentName.trimmingCharacters(in: .whitespaces),
            sortOrder: (environments.last?.sortOrder ?? -1) + 1
        )
        environment.repository = repo
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
        let repoUUID = environment.repository?.uuid
        let matches = (try? context.fetch(FetchDescriptor<Variable>(
            predicate: #Predicate { $0.environmentName == name }
        ))) ?? []
        let count = matches.filter { $0.target?.repository?.uuid == repoUUID }.count
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
