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
                        GridRow {
                            Text(key).fontDesign(.monospaced).fontWeight(.medium)
                            ForEach(environmentNames, id: \.self) { environmentName in
                                CompareCell(target: target, key: key, environmentName: environmentName,
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
    let onError: (String) -> Void
    @Environment(\.modelContext) private var context
    @State private var text = ""

    private var variable: Variable? {
        (target.variables ?? []).first {
            $0.key == key && $0.environmentName == environmentName && !$0.isIgnored
        }
    }

    var body: some View {
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
                        .onAppear { text = variable.value }
                        .onSubmit {
                            do { try VariableService.updateValue(variable, to: text, context: context) }
                            catch { onError(error.localizedDescription) }
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
        .frame(minWidth: 140, alignment: .leading)
    }
}
