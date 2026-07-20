import SwiftUI
import SwiftData
import AppKit

/// 변수 목록/편집 (PRD §3.3). (선택된 Target, 선택된 Environment) 기준.
struct VariablesView: View {
    let target: Target
    let environmentName: String
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var showAdd = false
    @State private var errorMessage: String?

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
                    description: search.isEmpty ? Text("+ 버튼으로 키를 추가하세요") : nil
                )
            }
        }
        .toolbar {
            Button("키 추가", systemImage: "plus") { showAdd = true }
        }
        .sheet(isPresented: $showAdd) {
            AddVariableSheet(target: target, environmentName: environmentName)
        }
        .alert("오류", isPresented: .constant(errorMessage != nil)) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
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

            Button("복사", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(VariableService.value(of: variable), forType: .string)
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
    @State private var key = ""
    @State private var value = ""
    @State private var note = ""
    @State private var isSecret = false
    @State private var errorMessage: String?

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
