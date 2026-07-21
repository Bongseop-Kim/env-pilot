import SwiftUI
import SwiftData

/// .envide 번들 가져오기 (PRD §3.14) — (패스프레이즈) → 미리보기 → §3.12와 동일한 충돌 정책으로 병합.
struct BundleImportSheet: View {
    let data: Data
    let workspace: Workspace
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var needsPassphrase = false
    @State private var passphrase = ""
    @State private var payload: BundleCodec.Payload?
    @State private var items: [BundleCodec.MergeItem] = []
    @State private var useFileValue: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import — .envide 번들")
                .font(SeedFont.t6(.bold))
                .padding()

            if payload != nil {
                preview
            } else if needsPassphrase {
                passphrasePrompt
            }

            if let errorMessage {
                SeedCallout(errorMessage, tone: .critical)
                    .padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .buttonStyle(.seed(.neutralWeak, size: .small))
                    .keyboardShortcut(.cancelAction)
                if payload != nil {
                    Button("가져오기 (\(applicableCount))") { run() }
                        .buttonStyle(.seed(.brandSolid, size: .small))
                        .keyboardShortcut(.defaultAction)
                        .disabled(applicableCount == 0 && items.isEmpty)
                } else if needsPassphrase {
                    Button("열기") { decrypt() }
                        .buttonStyle(.seed(.brandSolid, size: .small))
                        .keyboardShortcut(.defaultAction)
                        .disabled(passphrase.isEmpty)
                }
            }
            .padding()
        }
        .frame(width: 560, height: payload == nil ? 200 : 440)
        .onAppear(perform: open)
    }

    private var passphrasePrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("암호화된 번들입니다. 패스프레이즈를 입력하세요.")
            SeedTextField("패스프레이즈", text: $passphrase, secure: true)
                .onSubmit(decrypt)
        }
        .padding(.horizontal)
    }

    private var grouped: [(group: String, items: [BundleCodec.MergeItem])] {
        Dictionary(grouping: items, by: \.group)
            .sorted { $0.key < $1.key }
            .map { (group: $0.key, items: $0.value) }
    }

    private var applicableCount: Int {
        items.filter {
            switch $0.kind {
            case .add: true
            case .conflict: useFileValue.contains($0.id)
            case .same: false
            }
        }.count
    }

    private var preview: some View {
        List {
            if items.isEmpty {
                Text("변경할 항목이 없습니다 — 구조(Repository/Target/Environment)만 병합됩니다.")
                    .foregroundStyle(SeedColor.fgNeutralMuted)
            }
            ForEach(grouped, id: \.group) { section in
                Section(section.group) {
                    ForEach(section.items) { item in
                        row(item)
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ item: BundleCodec.MergeItem) -> some View {
        switch item.kind {
        case .add:
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(SeedColor.fgPositive)
                Text(item.key).fontDesign(.monospaced)
                Spacer()
                Text(item.newValue).foregroundStyle(SeedColor.fgNeutralMuted).fontDesign(.monospaced)
                    .lineLimit(1).truncationMode(.middle)
            }
        case .same:
            HStack {
                Image(systemName: "equal.circle").foregroundStyle(SeedColor.fgNeutralMuted)
                Text(item.key).fontDesign(.monospaced).foregroundStyle(SeedColor.fgNeutralMuted)
                Spacer()
                Text("동일 — 스킵").font(SeedFont.t3()).foregroundStyle(SeedColor.fgNeutralMuted)
            }
        case .conflict(let existing):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(SeedColor.fgBrand)
                    Text(item.key).fontDesign(.monospaced).fontWeight(.medium)
                    Spacer()
                    SeedSegmentedControl(selection: choiceBinding(item.id),
                                         items: [(true, "파일 값 사용"), (false, "기존 값 유지")])
                        .fixedSize()
                }
                Group {
                    Text("파일: \(item.newValue)")
                    Text("기존: \(existing)")
                }
                .font(SeedFont.t3()).fontDesign(.monospaced).foregroundStyle(SeedColor.fgNeutralMuted)
                .lineLimit(1).truncationMode(.middle)
                .padding(.leading, 24)
            }
        }
    }

    private func choiceBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { useFileValue.contains(id) },
            set: { useFile in
                if useFile { useFileValue.insert(id) } else { useFileValue.remove(id) }
            }
        )
    }

    private func open() {
        do {
            let decoded = try BundleCodec.decode(data)
            if decoded.needsPassphrase {
                needsPassphrase = true
            } else if let decodedPayload = decoded.payload {
                show(decodedPayload)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func decrypt() {
        do {
            show(try BundleCodec.decrypt(data, passphrase: passphrase))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func show(_ decodedPayload: BundleCodec.Payload) {
        payload = decodedPayload
        items = BundleCodec.plan(payload: decodedPayload, workspace: workspace)
        // 기본: 파일 값 사용 (§3.12)
        useFileValue = Set(items.compactMap {
            if case .conflict = $0.kind { $0.id } else { nil }
        })
    }

    private func run() {
        guard let payload else { return }
        do {
            try BundleCodec.execute(payload: payload, useFileValue: useFileValue,
                                    workspace: workspace, context: context)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
