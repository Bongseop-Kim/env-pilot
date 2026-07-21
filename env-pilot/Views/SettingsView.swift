import SwiftUI
import SwiftData
import ServiceManagement

/// 설정 (PRD §4.5) — Workspace 이름, 로그인 시 시작(§3.15).
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var workspaces: [Workspace]
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
                Toggle("Secret 표시·복사·해제 시 인증 요구", isOn: $requireAuthForSecrets)
                Text("Touch ID 또는 로그인 비밀번호로 승인합니다. 승인 후 60초간 재인증을 생략합니다.")
                    .font(SeedTypography.caption)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
            }

            Section("동기화") {
                Toggle("iCloud 동기화", isOn: $iCloudSyncEnabled)
                Text("같은 Apple 계정의 Mac 간에 데이터가 동기화됩니다. Secret은 iCloud Keychain으로 별도 동기화되며, 로컬 폴더 경로는 Mac마다 다시 연결해야 합니다. 변경은 앱을 다시 실행하면 적용됩니다.")
                    .font(SeedTypography.caption)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.seed)
        .frame(width: 480, height: 440)
    }
}
