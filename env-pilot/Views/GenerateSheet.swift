import SwiftUI

/// Generate 확인 시트 (PRD §3.4) — 플랜과 덮어쓰기 diff 미리보기를 보여주고 실행.
struct GenerateSheet: View {
    let plans: [GenerateService.Plan]
    let rootURL: URL
    let environmentName: String
    @Environment(\.dismiss) private var dismiss
    @State private var errors: [String] = []

    private var writablePlans: Int {
        plans.filter { $0.action == .create || $0.action == .overwrite }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Generate — \(environmentName)")
                .font(.headline)
                .padding()

            List(plans) { plan in
                PlanRow(plan: plan)
            }
            .frame(minHeight: 200)

            if !errors.isEmpty {
                ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red).padding(.horizontal) }
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("생성 (\(writablePlans))") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(writablePlans == 0)
            }
            .padding()
        }
        .frame(width: 520, height: 400)
    }

    private func run() {
        errors = GenerateService.execute(plans, rootURL: rootURL)
        if errors.isEmpty { dismiss() }
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
