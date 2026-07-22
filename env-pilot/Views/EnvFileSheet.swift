import SwiftUI
import SwiftData

/// 실제 .env 파일을 명시적으로 생성하거나 Repository 안에서 이름/경로를 변경한다.
struct EnvFileSheet: View {
    let repo: Repository
    let target: Target?
    let onSaved: (Target) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var relativePath: String
    @State private var errorMessage: String?

    init(repo: Repository, target: Target? = nil, onSaved: @escaping (Target) -> Void) {
        self.repo = repo
        self.target = target
        self.onSaved = onSaved
        _relativePath = State(initialValue: target?.envFilePath ?? ".env")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SeedSpacing.x5) {
            Text(target == nil ? "새 .env 파일" : ".env 파일 이름/경로 변경")
                .font(SeedTypography.title)
                .foregroundStyle(SeedColor.fgNeutral)

            SeedField(
                "Repository 기준 경로",
                description: "예: .env.local 또는 apps/api/.env.production · 상위 폴더는 이미 있어야 합니다"
            ) {
                SeedTextField(".env", text: $relativePath, isInvalid: errorMessage != nil)
                    .fontDesign(.monospaced)
                    .autocorrectionDisabled()
            }

            if let errorMessage {
                SeedCallout(errorMessage, tone: .critical)
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .buttonStyle(.seed(.neutralWeak, size: .small))
                    .keyboardShortcut(.cancelAction)
                Button(target == nil ? "생성" : "변경", action: save)
                    .buttonStyle(.seed(.brandSolid, size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(SeedSpacing.x5)
        .frame(width: 500)
    }

    private func save() {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else {
            errorMessage = "폴더에 접근할 수 없습니다. 경로를 다시 연결하세요."
            return
        }

        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let savedTarget: Target
            if let target {
                try EnvFileService.rename(
                    target, to: path, rootURL: rootURL, context: context)
                savedTarget = target
            } else {
                savedTarget = try EnvFileService.create(
                    relativePath: path, in: repo, rootURL: rootURL, context: context)
            }
            onSaved(savedTarget)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
