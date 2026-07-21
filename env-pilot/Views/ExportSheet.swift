import SwiftUI
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    // ponytail: Info.plist 타입 선언 대신 동적 UTType — fileImporter/Exporter에는 충분
    static let envide = UTType(filenameExtension: "envide", conformingTo: .json) ?? .json
}

/// .envide 데이터 래퍼 — fileExporter용 최소 구현.
struct EnvideDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.envide]
    var data = Data()

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// .envide 번들 내보내기 (PRD §3.14) — Repository/Workspace 단위, Secret 포함 시 패스프레이즈 필수.
struct ExportSheet: View {
    let repo: Repository
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var wholeWorkspace = false
    @State private var includeSecrets = false
    @State private var passphrase = ""
    @State private var passphraseConfirm = ""
    @State private var document: EnvideDocument?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export — .envide 번들")
                .font(.headline)

            Picker("범위", selection: $wholeWorkspace) {
                Text(repo.name).tag(false)
                Text("전체 Workspace").tag(true)
            }
            .pickerStyle(.radioGroup)

            Toggle("Secret 실값 포함", isOn: $includeSecrets)
            if includeSecrets {
                SecureField("패스프레이즈", text: $passphrase)
                SecureField("패스프레이즈 확인", text: $passphraseConfirm)
                Text("Secret이 포함되므로 파일 전체가 AES-GCM으로 암호화됩니다. 패스프레이즈를 잊으면 복구할 수 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Secret은 구조만 내보내고 값은 비웁니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("내보내기…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
        }
        .padding(20)
        .frame(width: 380)
        .fileExporter(
            isPresented: Binding(presence: $document),
            document: document,
            contentType: .envide,
            defaultFilename: wholeWorkspace ? "\(workspace.name).envide" : "\(repo.name).envide"
        ) { result in
            document = nil
            if case .success = result { dismiss() }
        }
    }

    private var canExport: Bool {
        !includeSecrets || (!passphrase.isEmpty && passphrase == passphraseConfirm)
    }

    private func export() {
        let repos = wholeWorkspace
            ? (workspace.repositories ?? []).sorted { $0.createdAt < $1.createdAt }
            : [repo]
        // 번들 포맷 v1 호환 — environments는 대상 repo들의 합집합
        var seen = Set<String>()
        let environments = repos.flatMap(\.environmentNames).filter { seen.insert($0).inserted }
        do {
            let payload = BundleCodec.makePayload(repos: repos, environments: environments,
                                                  includeSecrets: includeSecrets)
            let data = try BundleCodec.encode(payload, passphrase: includeSecrets ? passphrase : nil)
            document = EnvideDocument(data: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
