import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// 변수 목록/편집 (PRD §3.3) + Import 진입점 (§3.12). (선택된 Target, 선택된 Environment) 기준.
struct VariablesView: View {
    let target: Target
    let environmentName: String
    @Binding var pendingAddKey: String?   // Health에서 누락 키 클릭 시 프리필 (§3.8)
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var showAdd = false
    @State private var addSheetKey = ""
    @State private var showFilePicker = false
    @State private var importPlan: (items: [ImportService.Item], warnings: [String])?
    @State private var errorMessage: String?
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
                VariableRow(variable: variable, onError: { errorMessage = $0 })
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
            Menu {
                ForEach(CopyFormat.allCases, id: \.self) { format in
                    Button(format.rawValue) { copyAs(format) }
                }
            } label: {
                Label("Copy as…", systemImage: "doc.on.clipboard")
            }
            .help("현재 목록 전체를 dotenv / Shell exports / JSON 포맷으로 복사")
            Button("Example 생성", systemImage: "doc.badge.gearshape") { generateExample() }
                .help("현재 변수들로부터 \(target.examplePath) 파일 생성")
            Button("Import", systemImage: "square.and.arrow.up") { showFilePicker = true }
                .help("기존 .env 파일을 가져와 변수로 등록")
            Button("키 추가", systemImage: "plus") { addSheetKey = ""; showAdd = true }
                .help("새 변수 추가")
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
        .sheet(isPresented: .constant(importPlan != nil), onDismiss: { importPlan = nil }) {
            if let plan = importPlan {
                ImportSheet(items: plan.items, warnings: plan.warnings,
                            target: target, environmentName: environmentName)
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            importFile(url)
        }
        .onChange(of: pendingAddKey, initial: true) {
            if let key = pendingAddKey {
                addSheetKey = key
                showAdd = true
                pendingAddKey = nil
            }
        }
        .alert("오류", isPresented: .constant(errorMessage != nil)) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// §3.20 — 현재 Target × Environment 전체를 지정 포맷으로 복사. Secret 포함 시 §3.16 자동 삭제.
    private func copyAs(_ format: CopyFormat) {
        let all = (target.variables ?? [])
            .filter { $0.environmentName == environmentName && !$0.isIgnored }
        let values = Dictionary(uniqueKeysWithValues: all.map { ($0.key, VariableService.value(of: $0)) })
        ClipboardService.copy(format.render(values), clearAfterDelay: all.contains(where: \.isSecret))
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

/// 한 변수의 행: 값 인라인 편집, Secret 마스킹(클릭 시 일시 표시), 복사.
private struct VariableRow: View {
    let variable: Variable
    let onError: (String) -> Void
    @Environment(\.modelContext) private var context
    @State private var valueText = ""
    @State private var noteText = ""
    @State private var revealed = false
    @State private var showClipboardNote = false   // §3.16 복사 직후 안내

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                if variable.isSecret {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption)
                }
                Text(variable.key).fontDesign(.monospaced).fontWeight(.medium)
            }
            .frame(width: 220, alignment: .leading)

            if variable.isSecret && !revealed {
                Button("••••••••") { reveal() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("클릭하여 표시")
            } else {
                TextField("값 없음", text: $valueText)
                    .textFieldStyle(.plain)
                    .fontDesign(.monospaced)
                    .onSubmit(commitValue)
            }

            TextField("설명", text: $noteText)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 180)
                .onSubmit(commitNote)

            if showClipboardNote {
                Text("30초 후 클립보드에서 삭제됨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("복사", systemImage: "doc.on.doc") {
                // Secret만 30초 후 자동 삭제 대상 (§3.16)
                ClipboardService.copy(VariableService.value(of: variable),
                                      clearAfterDelay: variable.isSecret)
                if variable.isSecret {
                    showClipboardNote = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showClipboardNote = false }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .onAppear {
            valueText = variable.isSecret ? "" : variable.value
            noteText = variable.note ?? ""
        }
    }

    private func reveal() {
        valueText = VariableService.value(of: variable)
        revealed = true
    }

    private func commitValue() {
        do { try VariableService.updateValue(variable, to: valueText, context: context) }
        catch { onError(error.localizedDescription) }
    }

    private func commitNote() {
        do { try VariableService.updateNote(variable, to: noteText, context: context) }
        catch { onError(error.localizedDescription) }
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
        Form {
            Section("새 키 — \(environmentName)") {
                TextField("KEY", text: $key)
                    .fontDesign(.monospaced)
                    .autocorrectionDisabled()
                TextField("값", text: $value).fontDesign(.monospaced)
                TextField("설명 (선택)", text: $note)
                Toggle("Secret (Keychain에 저장)", isOn: $isSecret)
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
                Button("추가", action: add).disabled(key.isEmpty)
            }
        }
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
