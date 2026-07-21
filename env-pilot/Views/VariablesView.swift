import SwiftUI
import SwiftData
import AppKit

/// 변수 목록/편집 (PRD §3.3) + Import 진입점 (§3.12). (선택된 Target, 선택된 Environment) 기준.
struct VariablesView: View {
    let target: Target
    let environmentName: String
    @Binding var pendingAddKey: String?   // Health에서 누락 키 클릭 시 프리필 (§3.8)
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var showAdd = false
    @State private var addSheetKey = ""
    @State private var importPlan: (items: [ImportService.Item], warnings: [String])?
    @State private var errorMessage: String?
    @State private var snackbar: SeedSnackbarMessage?
    @State private var pendingExampleContent: String?   // §3.17 덮어쓰기 확인 대기 중인 내용

    private var variables: [Variable] {
        (target.variables ?? [])
            .filter { $0.environmentName == environmentName && !$0.isIgnored }
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
                            onNotify: { snackbar = $0 })
                    .contextMenu {
                        Button(variable.isSecret ? "Secret 해제" : "Secret으로 전환") {
                            do { try VariableService.setSecret(variable, !variable.isSecret, context: context) }
                            catch { errorMessage = error.localizedDescription }
                        }
                        Button("삭제", role: .destructive) {
                            do { try VariableService.delete(variable, context: context) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "키 또는 설명 검색")
        .overlay {
            if variables.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "키가 없습니다" : "검색 결과 없음",
                    systemImage: "key",
                    description: search.isEmpty ? Text("+ 로 추가하거나 기존 .env를 Import 하세요") : nil
                )
            }
        }
        .toolbar {
            Button("키 추가", systemImage: "plus") { addSheetKey = ""; showAdd = true }
                .help("새 변수 추가 (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            // 보조 액션은 하나로 묶어 툴바 과밀 방지 — 상위 툴바(Scan/Generate/Export)와 공존
            Menu {
                Button("Import — 기존 .env 가져오기", systemImage: "square.and.arrow.down") {
                    pickImportFile()
                }
                Button("Example 생성 — \(target.examplePath)", systemImage: "doc.badge.gearshape") {
                    generateExample()
                }
                Menu("Copy as…") {
                    ForEach(CopyFormat.allCases, id: \.self) { format in
                        Button(format.rawValue) { copyAs(format) }
                    }
                }
            } label: {
                Label("더 보기", systemImage: "ellipsis.circle")
            }
            .help("Import · Example 생성 · 전체 복사")
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
            AddVariableSheet(target: target, environmentName: environmentName, initialKey: addSheetKey)
        }
        .sheet(isPresented: Binding(presence: $importPlan)) {
            if let plan = importPlan {
                ImportSheet(items: plan.items, warnings: plan.warnings,
                            target: target, environmentName: environmentName)
            }
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

    /// §3.20 — 현재 Target × Environment 전체를 지정 포맷으로 복사. Secret 포함 시 §3.16 자동 삭제.
    private func copyAs(_ format: CopyFormat) {
        let all = (target.variables ?? [])
            .filter { $0.environmentName == environmentName && !$0.isIgnored }
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
            pendingExampleContent = content   // §3.4와 동일한 덮어쓰기 확인
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

    /// fileImporter는 조상 뷰(RepositoryDetailView)의 fileImporter와 충돌해 패널이 열리지 않고,
    /// 숨김 파일인 .env가 목록에 보이지도 않아 NSOpenPanel을 직접 사용한다.
    private func pickImportFile() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let repo = target.repository, let rootURL = RepositoryService.resolveBookmark(repo) {
            panel.directoryURL = target.relativePath == "."
                ? rootURL
                : rootURL.appendingPathComponent(target.relativePath)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importFile(url)
        }
    }

    private func importFile(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "파일을 읽을 수 없습니다: \(url.lastPathComponent)"
            return
        }
        importPlan = ImportService.plan(content: content, target: target, environmentName: environmentName)
    }
}

/// 한 변수의 행: 값 인라인 편집(Enter 또는 포커스 이탈 시 저장), Secret 마스킹(클릭 시 일시 표시), 복사.
private struct VariableRow: View {
    let variable: Variable
    let onError: (String) -> Void
    let onNotify: (SeedSnackbarMessage) -> Void
    @Environment(\.modelContext) private var context
    @State private var valueText = ""
    @State private var noteText = ""
    @State private var committedValue = ""   // blur 커밋 시 불필요한 저장 방지용 기준값
    @State private var committedNote = ""
    @State private var revealed = false
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
                    .help(variable.key)   // 고정폭 컬럼에서 잘린 긴 키 확인용
            }
            .frame(width: 220, alignment: .leading)

            if variable.isSecret && !revealed {
                Button("••••••••") { reveal() }
                    .buttonStyle(.plain)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("클릭하여 표시")
            } else {
                TextField("값 없음", text: $valueText)
                    .textFieldStyle(.plain)
                    .fontDesign(.monospaced)
                    .focused($focusedField, equals: .value)
                    .onSubmit(commitValue)
            }

            TextField("설명", text: $noteText)
                .textFieldStyle(.plain)
                .foregroundStyle(SeedColor.fgNeutralMuted)
                .frame(width: 180)
                .focused($focusedField, equals: .note)
                .onSubmit(commitNote)

            // 자리를 항상 확보해 나타났다 사라져도 레이아웃이 밀리지 않게
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(SeedColor.fgPositive)
                .opacity(savedFlash ? 1 : 0)
                .accessibilityLabel(savedFlash ? "저장됨" : "")

            Button("복사", systemImage: "doc.on.doc") {
                Task {
                    if variable.isSecret {
                        guard await BiometricGate.authorize(reason: "\(variable.key) 값을 복사") else { return }
                    }
                    // Secret만 30초 후 자동 삭제 대상 (§3.16)
                    ClipboardService.copy(VariableService.value(of: variable),
                                          clearAfterDelay: variable.isSecret)
                    onNotify(SeedSnackbarMessage(
                        variable.isSecret ? "복사됨 — 30초 후 클립보드에서 삭제" : "값 복사됨",
                        tone: .positive))
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.seedIcon())
            .help(variable.isSecret ? "값 복사 — 30초 후 클립보드에서 자동 삭제됩니다" : "값 복사")
        }
        .seedListRow()
        .onAppear {
            valueText = variable.isSecret ? "" : variable.value
            noteText = variable.note ?? ""
            committedValue = valueText
            committedNote = noteText
        }
        .onChange(of: focusedField) { old, _ in
            // Enter 없이 다른 곳을 클릭해도 저장 (§3.3 인라인 편집)
            if old == .value { commitValue() }
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
    let environmentName: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var value = ""
    @State private var note = ""
    @State private var isSecret = false
    @State private var errorMessage: String?

    init(target: Target, environmentName: String, initialKey: String = "") {
        self.target = target
        self.environmentName = environmentName
        _key = State(initialValue: initialKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SeedSpacing.x5) {
            Text("새 키 — \(environmentName)")
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
                environmentName: environmentName,
                target: target,
                context: context
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
