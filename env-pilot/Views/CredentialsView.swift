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
                CredentialRow(credential: credential, onError: { errorMessage = $0 })
                    .contextMenu {
                        Button("삭제", role: .destructive) {
                            do { try CredentialService.delete(credential, context: context) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
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
        .sheet(isPresented: $showAdd) {
            AddCredentialSheet(repo: repo)
        }
        .alert("오류", isPresented: .constant(errorMessage != nil)) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

/// 한 계정의 행: 아이디 복사, 비밀번호 마스킹(클릭 시 일시 표시)/복사, 주소 열기.
private struct CredentialRow: View {
    let credential: Credential
    let onError: (String) -> Void
    @Environment(\.modelContext) private var context
    @State private var passwordText = ""
    @State private var revealed = false
    @State private var showClipboardNote = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.label).fontWeight(.medium)
                if let note = credential.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 180, alignment: .leading)

            HStack(spacing: 4) {
                Text(credential.username).fontDesign(.monospaced).textSelection(.enabled)
                Button("아이디 복사", systemImage: "doc.on.doc") {
                    ClipboardService.copy(credential.username, clearAfterDelay: false)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            .frame(width: 220, alignment: .leading)

            if revealed {
                TextField("비밀번호", text: $passwordText)
                    .textFieldStyle(.plain)
                    .fontDesign(.monospaced)
                    .onSubmit(commitPassword)
            } else {
                Button("••••••••") { reveal() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("클릭하여 표시")
            }

            if showClipboardNote {
                Text("30초 후 클립보드에서 삭제됨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let url = CredentialService.openableURL(credential.urlString) {
                Button("열기", systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(url)  // 웹 주소와 앱 스키마 모두 처리
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(credential.urlString ?? "")
            }
            Button("비밀번호 복사", systemImage: "doc.on.doc") {
                Task {
                    guard await BiometricGate.authorize(reason: "\(credential.label) 비밀번호를 복사") else { return }
                    ClipboardService.copy(CredentialService.password(of: credential), clearAfterDelay: true)
                    showClipboardNote = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showClipboardNote = false }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("비밀번호 복사")
        }
        .padding(.vertical, 2)
    }

    private func reveal() {
        Task {
            guard await BiometricGate.authorize(reason: "\(credential.label) 비밀번호를 표시") else { return }
            passwordText = CredentialService.password(of: credential)
            revealed = true
        }
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
        Form {
            Section("새 계정 — \(repo.name)") {
                TextField("이름 (예: Staging 관리자)", text: $label)
                TextField("아이디 / 이메일", text: $username)
                    .fontDesign(.monospaced)
                    .autocorrectionDisabled()
                SecureField("비밀번호 (Keychain에 저장)", text: $password)
                TextField("주소 — 웹 URL 또는 앱 스키마 (선택)", text: $urlString)
                    .fontDesign(.monospaced)
                    .autocorrectionDisabled()
                TextField("설명 (선택)", text: $note)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.bottom)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("취소") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("추가", action: add).disabled(label.isEmpty)
            }
        }
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
