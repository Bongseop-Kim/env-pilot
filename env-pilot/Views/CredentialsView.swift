import SwiftUI
import SwiftData
import AppKit

/// 프로젝트 스코프 계정 목록 — Repository 단위 (Environment 무관).
/// 표시/복사 규칙은 Variable Secret과 동일: BiometricGate + 클립보드 자동 삭제 (§3.16).
struct CredentialsView: View {
    let repo: Repository
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var showAdd = false
    @State private var errorMessage: String?
    @State private var snackbar: SeedSnackbarMessage?
    @State private var credentialPendingDelete: Credential?

    private var credentials: [Credential] {
        (repo.credentials ?? [])
            .filter {
                search.isEmpty
                    || $0.label.localizedCaseInsensitiveContains(search)
                    || $0.username.localizedCaseInsensitiveContains(search)
                    || ($0.urlString ?? "").localizedCaseInsensitiveContains(search)
            }
            .sorted { $0.label < $1.label }
    }

    var body: some View {
        List {
            ForEach(credentials) { credential in
                CredentialRow(credential: credential, onError: { errorMessage = $0 },
                              onNotify: { snackbar = $0 },
                              onDelete: { credentialPendingDelete = credential })
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "이름, 아이디 또는 주소 검색")
        .overlay {
            if credentials.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "계정이 없습니다" : "검색 결과 없음",
                    systemImage: "person.badge.key",
                    description: search.isEmpty
                        ? Text("+ 로 이 프로젝트의 테스트 계정·콘솔 로그인을 추가하세요") : nil
                )
            }
        }
        .toolbar {
            Button("계정 추가", systemImage: "plus") { showAdd = true }
                .help("이 프로젝트에서 쓰는 계정 추가 (비밀번호는 Keychain에 저장)")
        }
        .confirmationDialog(
            "'\(credentialPendingDelete?.label ?? "")' 계정을 삭제할까요?",
            isPresented: Binding(presence: $credentialPendingDelete), titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let credential = credentialPendingDelete {
                    do { try CredentialService.delete(credential, context: context) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("Keychain의 비밀번호가 함께 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
        }
        .sheet(isPresented: $showAdd) {
            AddCredentialSheet(repo: repo)
        }
        .errorAlert($errorMessage)
        .snackbar($snackbar)
    }
}

/// 한 계정의 행: 아이디 클릭=복사. 비밀번호는 클릭=표시(인증) → 클릭=복사, 더블클릭=편집. 주소 열기, 더보기 메뉴.
private struct CredentialRow: View {
    let credential: Credential
    let onError: (String) -> Void
    let onNotify: (SeedSnackbarMessage) -> Void
    let onDelete: () -> Void
    @Environment(\.modelContext) private var context
    @State private var passwordText = ""
    @State private var revealed = false
    @State private var isEditing = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.label).fontWeight(.medium)
                if let note = credential.note {
                    Text(note).font(SeedTypography.caption)
                        .foregroundStyle(SeedColor.fgNeutralMuted).lineLimit(1)
                        .help(note)
                }
            }
            .frame(width: 180, alignment: .leading)

            Text(credential.username).fontDesign(.monospaced)
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    ClipboardService.copy(credential.username, clearAfterDelay: false)
                    onNotify(SeedSnackbarMessage("아이디 복사됨", tone: .positive))
                }
                .help("클릭하여 아이디 복사 — \(credential.username)")

            if !revealed {
                Button("••••••••") { reveal() }
                    .buttonStyle(.plain)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("클릭하여 표시 — 표시된 비밀번호는 클릭하면 복사, 더블클릭하면 편집")
            } else if !isEditing {
                Text(passwordText.isEmpty ? "비밀번호 없음" : passwordText)
                    .fontDesign(.monospaced)
                    .foregroundStyle(passwordText.isEmpty ? SeedColor.fgNeutralMuted : SeedColor.fgNeutral)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        isEditing = true
                        passwordFocused = true
                    }
                    .onTapGesture { copyPassword() }
                    .help("클릭하여 복사, 더블클릭하여 편집")
            } else {
                TextField("비밀번호", text: $passwordText)
                    .textFieldStyle(.plain)
                    .fontDesign(.monospaced)
                    .focused($passwordFocused)
                    .onSubmit(commitPassword)
            }

            if let url = CredentialService.openableURL(credential.urlString) {
                Button("열기", systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(url)  // 웹 주소와 앱 스키마 모두 처리
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.seedIcon())
                .help(credential.urlString ?? "")
            }
            Menu {
                Button("삭제", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.seedIcon())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("더보기")
        }
        .seedListRow()
        .onChange(of: passwordFocused) { old, new in
            // Enter 없이 다른 곳을 클릭해도 저장하고 복사 모드로 복귀 (§3.3 인라인 편집)
            if old && !new && isEditing {
                commitPassword()
                isEditing = false
            }
        }
    }

    private func reveal() {
        Task {
            guard await BiometricGate.authorize(reason: "\(credential.label) 비밀번호를 표시") else { return }
            passwordText = CredentialService.password(of: credential)
            revealed = true
        }
    }

    /// 표시(인증) 이후의 복사 — 이미 화면에 보이는 값이라 재인증하지 않는다.
    private func copyPassword() {
        ClipboardService.copy(CredentialService.password(of: credential), clearAfterDelay: true)
        onNotify(SeedSnackbarMessage("비밀번호 복사됨 — 30초 후 클립보드에서 삭제", tone: .positive))
    }

    private func commitPassword() {
        do { try CredentialService.updatePassword(credential, to: passwordText, context: context) }
        catch { onError(error.localizedDescription) }
    }
}

private struct AddCredentialSheet: View {
    let repo: Repository
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var username = ""
    @State private var password = ""
    @State private var urlString = ""
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SeedSpacing.x5) {
            Text("새 계정 — \(repo.name)")
                .font(SeedTypography.title)
                .foregroundStyle(SeedColor.fgNeutral)
            SeedField("이름") {
                SeedTextField("예: Staging 관리자", text: $label)
            }
            SeedField("아이디 / 이메일") {
                SeedTextField("", text: $username)
                    .fontDesign(.monospaced)
                    .autocorrectionDisabled()
            }
            SeedField("비밀번호", description: "Keychain에 저장됩니다") {
                SeedTextField("", text: $password, secure: true)
            }
            SeedField("주소 (선택)", description: "웹 URL 또는 앱 스키마") {
                SeedTextField("", text: $urlString)
                    .fontDesign(.monospaced)
                    .autocorrectionDisabled()
            }
            SeedField("설명 (선택)") {
                SeedTextField("", text: $note)
            }
            if let errorMessage {
                SeedCallout(errorMessage, tone: .critical)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .buttonStyle(.seed(.neutralWeak, size: .small))
                    .keyboardShortcut(.cancelAction)
                Button("추가", action: add)
                    .buttonStyle(.seed(.brandSolid, size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.isEmpty)
            }
        }
        .padding(SeedSpacing.x5)
        .frame(width: 420)
    }

    private func add() {
        do {
            try CredentialService.create(
                label: label.trimmingCharacters(in: .whitespaces),
                username: username.trimmingCharacters(in: .whitespaces),
                password: password,
                urlString: urlString.trimmingCharacters(in: .whitespaces),
                note: note,
                repository: repo,
                context: context
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
