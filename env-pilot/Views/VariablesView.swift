import SwiftUI
import SwiftData

/// 선택한 실제 env 파일의 변수 목록/편집.
struct VariablesView: View {
    let target: Target
    @Binding var pendingAddKey: String?   // Health에서 누락 키 클릭 시 프리필 (§3.8)
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var showAdd = false
    @State private var addSheetKey = ""
    @State private var errorMessage: String?
    @State private var snackbar: SeedSnackbarMessage?
    @State private var pendingExampleContent: String?   // §3.17 덮어쓰기 확인 대기 중인 내용
    @State private var variablePendingDelete: Variable?

    private var variables: [Variable] {
        (target.variables ?? [])
            .filter { $0.environmentName == target.envFilePath && !$0.isIgnored }
            .filter {
                search.isEmpty
                    || $0.key.localizedCaseInsensitiveContains(search)
                    || ($0.note ?? "").localizedCaseInsensitiveContains(search)
            }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            ForEach(variables) { variable in
                VariableRow(variable: variable, onError: { errorMessage = $0 },
                            onNotify: { snackbar = $0 },
                            onToggleSecret: { setSecret(variable, to: !variable.isSecret) },
                            onDelete: { variablePendingDelete = variable })
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "키 또는 설명 검색")
        .overlay {
            if variables.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "키가 없습니다" : "검색 결과 없음",
                    systemImage: "key",
                    description: search.isEmpty ? Text("+ 버튼으로 변수를 추가하세요") : nil
                )
            }
        }
        .toolbar {
            Button("키 추가", systemImage: "plus") { addSheetKey = ""; showAdd = true }
                .help("새 변수 추가 (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            Button("Example 생성", systemImage: "doc.badge.gearshape") {
                generateExample()
            }
            .help("Example 생성 — \(target.examplePath)")
            Menu("전체 복사", systemImage: "doc.on.doc") {
                ForEach(CopyFormat.allCases, id: \.self) { format in
                    Button(format.rawValue) { copyAs(format) }
                }
            }
            .help("현재 env 파일을 포맷별로 복사")
        }
        .confirmationDialog(
            "\(variablePendingDelete?.key ?? "") 키를 삭제할까요?",
            isPresented: Binding(presence: $variablePendingDelete), titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let variable = variablePendingDelete {
                    do { try VariableService.delete(variable, context: context) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(variablePendingDelete?.isSecret == true
                 ? "Keychain의 Secret 값이 함께 삭제됩니다. 이 작업은 되돌릴 수 없습니다."
                 : "이 작업은 되돌릴 수 없습니다.")
        }
        .confirmationDialog("\(target.examplePath)이 이미 있고 내용이 다릅니다. 덮어쓸까요?",
                            isPresented: .constant(pendingExampleContent != nil), titleVisibility: .visible) {
            Button("덮어쓰기") {
                if let content = pendingExampleContent { writeExample(content) }
                pendingExampleContent = nil
            }
            Button("취소", role: .cancel) { pendingExampleContent = nil }
        }
        .sheet(isPresented: $showAdd) {
            AddVariableSheet(target: target, initialKey: addSheetKey)
        }
        .onChange(of: pendingAddKey, initial: true) {
            if let key = pendingAddKey {
                addSheetKey = key
                showAdd = true
                pendingAddKey = nil
            }
        }
        .errorAlert($errorMessage)
        .snackbar($snackbar)
    }

    private func setSecret(_ variable: Variable, to isSecret: Bool) {
        Task {
            if !isSecret {
                guard await BiometricGate.authorize(reason: "\(variable.key) Secret을 해제") else { return }
            }
            do { try VariableService.setSecret(variable, isSecret, context: context) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    /// §3.20 — 현재 env 파일 전체를 지정 포맷으로 복사. Secret 포함 시 §3.16 자동 삭제.
    private func copyAs(_ format: CopyFormat) {
        let all = (target.variables ?? [])
            .filter { $0.environmentName == target.envFilePath && !$0.isIgnored }
        let hasSecret = all.contains(where: \.isSecret)
        Task {
            if hasSecret {
                guard await BiometricGate.authorize(reason: "Secret이 포함된 목록을 복사") else { return }
            }
            let values = Dictionary(uniqueKeysWithValues: all.map { ($0.key, VariableService.value(of: $0)) })
            ClipboardService.copy(format.render(values), clearAfterDelay: hasSecret)
            snackbar = SeedSnackbarMessage(
                hasSecret ? "\(format.rawValue) 복사됨 — 30초 후 클립보드에서 삭제" : "\(format.rawValue) 복사됨",
                tone: .positive)
        }
    }

    /// §3.17 — example 역생성. 기존 파일과 다르면 덮어쓰기 확인.
    private func generateExample() {
        guard let repo = target.repository, let rootURL = RepositoryService.resolveBookmark(repo) else {
            errorMessage = "폴더에 접근할 수 없습니다. 경로를 다시 연결하세요."
            return
        }
        let content = ExampleDiffService.exampleContent(for: target)
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        let dir = target.relativePath == "." ? rootURL : rootURL.appendingPathComponent(target.relativePath)
        let existing = try? String(contentsOf: dir.appendingPathComponent(target.examplePath), encoding: .utf8)
        if hasAccess { rootURL.stopAccessingSecurityScopedResource() }

        if let existing, existing != content {
            pendingExampleContent = content
        } else {
            writeExample(content)
        }
    }

    private func writeExample(_ content: String) {
        guard let repo = target.repository, let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        do {
            try ExampleDiffService.writeExample(content: content, target: target, rootURL: rootURL)
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

/// 한 변수의 행: 키 클릭=복사. Secret 값은 클릭=표시(인증) → 클릭=복사, 더블클릭=편집.
/// 일반 값은 인라인 편집(Enter 또는 포커스 이탈 시 저장). 더보기 메뉴(Secret 전환·삭제).
private struct VariableRow: View {
    let variable: Variable
    let onError: (String) -> Void
    let onNotify: (SeedSnackbarMessage) -> Void
    let onToggleSecret: () -> Void
    let onDelete: () -> Void
    @Environment(\.modelContext) private var context
    @State private var valueText = ""
    @State private var noteText = ""
    @State private var committedValue = ""   // blur 커밋 시 불필요한 저장 방지용 기준값
    @State private var committedNote = ""
    @State private var revealed = false
    @State private var isEditingValue = false   // Secret은 표시 후 클릭=복사, 더블클릭=편집
    @State private var savedFlash = false    // 저장 직후 체크마크
    @FocusState private var focusedField: Field?

    private enum Field { case value, note }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                if variable.isSecret {
                    Image(systemName: "lock.fill").foregroundStyle(SeedColor.fgNeutralMuted).font(SeedTypography.body)
                }
                Text(variable.key).fontDesign(.monospaced).fontWeight(.medium)
            }
            .frame(width: 220, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                ClipboardService.copy(variable.key, clearAfterDelay: false)
                onNotify(SeedSnackbarMessage("키 복사됨", tone: .positive))
            }
            .help("클릭하여 키 복사 — \(variable.key)")

            if variable.isSecret && !revealed {
                Button("••••••••") { reveal() }
                    .buttonStyle(.plain)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("클릭하여 표시 — 표시된 값은 클릭하면 복사, 더블클릭하면 편집")
            } else if variable.isSecret && !isEditingValue {
                Text(valueText.isEmpty ? "값 없음" : valueText)
                    .fontDesign(.monospaced)
                    .foregroundStyle(valueText.isEmpty ? SeedColor.fgNeutralMuted : SeedColor.fgNeutral)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        isEditingValue = true
                        focusedField = .value
                    }
                    .onTapGesture { copyValue() }
                    .help("클릭하여 복사, 더블클릭하여 편집")
            } else {
                TextField("값 없음", text: $valueText)
                    .textFieldStyle(.plain)
                    .fontDesign(.monospaced)
                    .focused($focusedField, equals: .value)
                    .onSubmit(commitValue)
            }

            TextField("설명", text: $noteText)
                .textFieldStyle(.plain)
                .font(SeedTypography.caption)
                .foregroundStyle(SeedColor.fgNeutralMuted)
                .frame(width: 110)
                .focused($focusedField, equals: .note)
                .onSubmit(commitNote)

            // 자리를 항상 확보해 나타났다 사라져도 레이아웃이 밀리지 않게
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(SeedColor.fgPositive)
                .opacity(savedFlash ? 1 : 0)
                .accessibilityLabel(savedFlash ? "저장됨" : "")

            Menu {
                Button(variable.isSecret ? "Secret 해제" : "Secret으로 전환",
                       systemImage: variable.isSecret ? "lock.open" : "lock",
                       action: onToggleSecret)
                Divider()
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
        .onAppear {
            reloadValueFromModel()
            noteText = variable.note ?? ""
            committedNote = noteText
        }
        .onChange(of: variable.updatedAt) {
            guard valueText == committedValue else { return }
            reloadValueFromModel()
        }
        .onChange(of: focusedField) { old, _ in
            // Enter 없이 다른 곳을 클릭해도 저장 (§3.3 인라인 편집)
            if old == .value { commitValue(); isEditingValue = false }
            if old == .note { commitNote() }
        }
    }

    private func reveal() {
        Task {
            guard await BiometricGate.authorize(reason: "\(variable.key) 값을 표시") else { return }
            valueText = VariableService.value(of: variable)
            committedValue = valueText
            revealed = true
        }
    }

    /// 표시(인증) 이후의 복사 — grace 개념과 별개로, 이미 화면에 보이는 값이라 재인증하지 않는다.
    private func copyValue() {
        ClipboardService.copy(VariableService.value(of: variable), clearAfterDelay: variable.isSecret)
        onNotify(SeedSnackbarMessage(
            variable.isSecret ? "복사됨 — 30초 후 클립보드에서 삭제" : "값 복사됨",
            tone: .positive))
    }

    private func reloadValueFromModel() {
        valueText = variable.isSecret
            ? (revealed ? VariableService.value(of: variable) : "")
            : variable.value
        committedValue = valueText
    }

    private func flashSaved() {
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedFlash = false }
    }

    private func commitValue() {
        guard valueText != committedValue else { return }
        do {
            try VariableService.updateValue(variable, to: valueText, context: context)
            committedValue = valueText
            flashSaved()
        } catch { onError(error.localizedDescription) }
    }

    private func commitNote() {
        guard noteText != committedNote else { return }
        do {
            try VariableService.updateNote(variable, to: noteText, context: context)
            committedNote = noteText
            flashSaved()
        } catch { onError(error.localizedDescription) }
    }
}

private struct AddVariableSheet: View {
    let target: Target
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var value = ""
    @State private var note = ""
    @State private var isSecret = false
    @State private var errorMessage: String?

    init(target: Target, initialKey: String = "") {
        self.target = target
        _key = State(initialValue: initialKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SeedSpacing.x5) {
            Text("새 키")
                .font(SeedTypography.title)
                .foregroundStyle(SeedColor.fgNeutral)
            SeedField("KEY") {
                SeedTextField("예: API_KEY", text: $key)
                    .fontDesign(.monospaced)
                    .autocorrectionDisabled()
            }
            SeedField("값") {
                SeedTextField("", text: $value).fontDesign(.monospaced)
            }
            SeedField("설명 (선택)") {
                SeedTextField("", text: $note)
            }
            Toggle("Secret (Keychain에 저장)", isOn: $isSecret)
                .toggleStyle(.seed)
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
                    .disabled(key.isEmpty)
            }
        }
        .padding(SeedSpacing.x5)
        .frame(width: 420)
    }

    private func add() {
        do {
            try VariableService.create(
                key: key.trimmingCharacters(in: .whitespaces),
                value: value,
                note: note.isEmpty ? nil : note,
                isSecret: isSecret,
                environmentName: target.envFilePath,
                target: target,
                context: context
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
