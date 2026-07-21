import SwiftUI
import SwiftData

/// Compare 탭 (PRD §3.9) — 키 × Environment 매트릭스. 누락 셀 클릭으로 즉시 생성.
struct CompareView: View {
    let target: Target
    let environmentNames: [String]
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?

    private var keys: [String] {
        Set((target.variables ?? []).filter { !$0.isIgnored }.map(\.key)).sorted()
    }

    /// §3.21 — 같은 키의 값이 동일한 다른 Environment 목록 (빈 값 제외). 정보성 경고, Health 미반영.
    private func duplicateEnvironments(for key: String) -> [String: [String]] {
        var valueByEnv: [String: String] = [:]
        for variable in (target.variables ?? [])
        where variable.key == key && !variable.isIgnored && environmentNames.contains(variable.environmentName) {
            valueByEnv[variable.environmentName] = VariableService.value(of: variable)
        }
        var result: [String: [String]] = [:]
        for (env, value) in valueByEnv where !value.isEmpty {
            let others = valueByEnv.filter { $0.key != env && $0.value == value }.keys.sorted()
            if !others.isEmpty { result[env] = others }
        }
        return result
    }

    var body: some View {
        if keys.isEmpty {
            ContentUnavailableView("키가 없습니다", systemImage: "key",
                                   description: Text("Variables 탭에서 키를 추가하세요"))
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Key").font(.caption).foregroundStyle(.secondary)
                        ForEach(environmentNames, id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                                .frame(minWidth: 140, alignment: .leading)
                        }
                    }
                    Divider()
                    ForEach(keys, id: \.self) { key in
                        let duplicates = duplicateEnvironments(for: key)
                        GridRow {
                            Text(key).fontDesign(.monospaced).fontWeight(.medium)
                            ForEach(environmentNames, id: \.self) { environmentName in
                                CompareCell(target: target, key: key, environmentName: environmentName,
                                            duplicateWith: duplicates[environmentName] ?? [],
                                            onError: { errorMessage = $0 })
                            }
                        }
                    }
                }
                .padding()
            }
            .alert("오류", isPresented: .constant(errorMessage != nil)) {
                Button("확인") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private struct CompareCell: View {
    let target: Target
    let key: String
    let environmentName: String
    let duplicateWith: [String]   // §3.21 같은 값을 가진 다른 Environment
    let onError: (String) -> Void
    @Environment(\.modelContext) private var context
    @State private var text = ""
    @FocusState private var focused: Bool

    private var variable: Variable? {
        (target.variables ?? []).first {
            $0.key == key && $0.environmentName == environmentName && !$0.isIgnored
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            cellContent
            if !duplicateWith.isEmpty {
                Image(systemName: "equal.circle.fill")
                    .foregroundStyle(.yellow)
                    .help("\(duplicateWith.joined(separator: ", "))와 값이 동일합니다")
            }
        }
        .frame(minWidth: 140, alignment: .leading)
    }

    @ViewBuilder private var cellContent: some View {
        Group {
            if let variable {
                if variable.isSecret {
                    // ponytail: Compare에서 Secret은 읽기 전용 마스킹 — 편집은 Variables 탭에서
                    Label("••••••", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("빈 값", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                        .focused($focused)
                        .onAppear { text = variable.value }
                        .onSubmit { commit(variable) }
                        .onChange(of: focused) { _, isFocused in
                            // Enter 없이 다른 셀을 클릭해도 저장
                            if !isFocused { commit(variable) }
                        }
                }
            } else {
                // 누락 셀: 클릭 → 빈 변수 생성 → 즉시 입력 가능 (§3.9 수용 기준)
                Button {
                    do {
                        try VariableService.create(key: key, value: "", environmentName: environmentName,
                                                   target: target, context: context)
                    } catch { onError(error.localizedDescription) }
                } label: {
                    Label("누락", systemImage: "plus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func commit(_ variable: Variable) {
        guard text != variable.value else { return }
        do { try VariableService.updateValue(variable, to: text, context: context) }
        catch { onError(error.localizedDescription) }
    }
}
