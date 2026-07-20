import SwiftUI

/// Generate 확인 시트 (PRD §3.4) — 플랜과 덮어쓰기 diff 미리보기를 보여주고 실행.
/// 실행 후 Git Safety 검사 (§3.4 5단계, §3.11).
struct GenerateSheet: View {
    let repo: Repository
    let plans: [GenerateService.Plan]
    let rootURL: URL
    let environmentName: String
    @Environment(\.dismiss) private var dismiss
    @State private var errors: [String] = []
    @State private var safetyIssues: [GitSafetyService.Report]?

    private var writablePlans: Int {
        plans.filter { $0.action == .create || $0.action == .overwrite }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Generate — \(environmentName)")
                .font(.headline)
                .padding()

            if let issues = safetyIssues {
                safetyWarning(issues)
            } else {
                List(plans) { plan in
                    PlanRow(plan: plan)
                }
                .frame(minHeight: 200)
            }

            if !errors.isEmpty {
                ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red).padding(.horizontal) }
            }

            HStack {
                Spacer()
                if safetyIssues == nil {
                    Button("취소") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("생성 (\(writablePlans))") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(writablePlans == 0)
                } else {
                    Button("닫기") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 400)
    }

    private func run() {
        errors = GenerateService.execute(plans, rootURL: rootURL)
        guard errors.isEmpty else { return }

        // 생성 직후 Git Safety — 출력 파일이 커밋될 위험이 있으면 경고 (§3.4)
        let written = Set(plans.filter { $0.action == .create || $0.action == .overwrite }.map(\.targetPath))
        let issues = GitSafetyService.check(repo: repo, rootURL: rootURL)
            .filter { written.contains($0.targetPath) && $0.hasIssue }
        if issues.isEmpty {
            dismiss()
        } else {
            safetyIssues = issues
        }
    }

    private func safetyWarning(_ issues: [GitSafetyService.Report]) -> some View {
        List(issues) { report in
            VStack(alignment: .leading, spacing: 4) {
                Label(report.outputRelativePath, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fontDesign(.monospaced)
                HStack {
                    if !report.isIgnored {
                        Text(".gitignore에 없습니다 — 커밋될 수 있습니다").font(.caption)
                        Button(".gitignore에 추가") {
                            try? GitSafetyService.addToGitignore(
                                line: (report.outputRelativePath as NSString).lastPathComponent,
                                rootURL: rootURL)
                            let paths = Set(issues.map(\.targetPath))
                            let remaining = GitSafetyService.check(repo: repo, rootURL: rootURL)
                                .filter { paths.contains($0.targetPath) && $0.hasIssue }
                            if remaining.isEmpty { dismiss() } else { safetyIssues = remaining }
                        }
                        .controlSize(.small)
                    }
                    if report.isTracked {
                        Text("이미 Git에 커밋됨 — git rm --cached 필요").font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .frame(minHeight: 200)
    }
}

private struct PlanRow: View {
    let plan: GenerateService.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon.0).foregroundStyle(icon.1)
                Text(plan.targetPath).fontWeight(.medium)
                Text(plan.outputURL.lastPathComponent)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if plan.action == .overwrite, let existing = plan.existingContent {
                let diff = GenerateService.lineDiff(old: existing, new: plan.content)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(diff.removed, id: \.self) { line in
                        Text("− \(line)").foregroundStyle(.red)
                    }
                    ForEach(diff.added, id: \.self) { line in
                        Text("+ \(line)").foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .fontDesign(.monospaced)
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: (String, Color) {
        switch plan.action {
        case .create: ("plus.circle.fill", .green)
        case .overwrite: ("exclamationmark.triangle.fill", .orange)
        case .unchanged: ("checkmark.circle", .secondary)
        case .skipEmpty: ("minus.circle", .secondary)
        case .missingDir: ("xmark.circle.fill", .red)
        }
    }

    private var label: String {
        switch plan.action {
        case .create: "새로 생성"
        case .overwrite: "덮어쓰기"
        case .unchanged: "변경 없음"
        case .skipEmpty: "변수 없음 — 스킵"
        case .missingDir: "디렉토리 없음"
        }
    }
}
