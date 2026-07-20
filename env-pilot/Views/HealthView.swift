import SwiftUI

/// Health 탭 (PRD §3.8) — Target × Environment 판정 상세 + Git Safety 이슈.
struct HealthView: View {
    let items: [HealthService.Item]
    let safetyReports: [GitSafetyService.Report]
    let onSelectMissingKey: (_ targetPath: String, _ environmentName: String, _ key: String) -> Void
    let onAddToGitignore: (_ fileName: String) -> Void
    let onFixPermissions: (_ report: GitSafetyService.Report) -> Void

    private var allHealthy: Bool {
        items.allSatisfy { $0.status == .healthy } && !safetyReports.contains(where: \.hasIssue)
    }

    var body: some View {
        if items.isEmpty && safetyReports.allSatisfy({ !$0.hasIssue }) {
            ContentUnavailableView("판정 대상 없음", systemImage: "questionmark.circle",
                                   description: Text(".env.example이 있는 Target이 없습니다"))
        } else if allHealthy {
            ContentUnavailableView("All Healthy", systemImage: "checkmark.seal.fill",
                                   description: Text("모든 Environment가 example 키를 충족합니다"))
        } else {
            List {
                healthSections
                safetySection
            }
        }
    }

    @ViewBuilder private var healthSections: some View {
        let grouped = Dictionary(grouping: items, by: \.targetPath)
        ForEach(grouped.keys.sorted(), id: \.self) { targetPath in
            Section(targetPath) {
                ForEach(grouped[targetPath] ?? []) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.status.symbol)
                        Text(item.environmentName).frame(width: 110, alignment: .leading)
                        keyChips(item)
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder private func keyChips(_ item: HealthService.Item) -> some View {
        if item.status == .healthy {
            Text("Healthy").foregroundStyle(.secondary).font(.caption)
        } else {
            // 누락 키 클릭 → 해당 Variable 입력으로 이동 (§3.8 수용 기준)
            WrappingHStack {
                ForEach(item.missingKeys, id: \.self) { key in
                    Button("\(key) 누락") {
                        onSelectMissingKey(item.targetPath, item.environmentName, key)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
                ForEach(item.emptyValueKeys, id: \.self) { key in
                    Button("\(key) 빈 값") {
                        onSelectMissingKey(item.targetPath, item.environmentName, key)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.yellow)
                }
            }
        }
    }

    @ViewBuilder private var safetySection: some View {
        let issues = safetyReports.filter(\.hasIssue)
        if !issues.isEmpty {
            Section("Git Safety") {
                ForEach(issues) { report in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.outputRelativePath).fontDesign(.monospaced)
                        HStack {
                            if !report.isIgnored {
                                Label(".gitignore에 없음", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Button(".gitignore에 추가") {
                                    onAddToGitignore((report.outputRelativePath as NSString).lastPathComponent)
                                }
                                .controlSize(.small)
                            }
                            if report.isTracked {
                                Label("Git에 커밋되어 있음 — git rm --cached로 제거 필요", systemImage: "xmark.octagon.fill")
                                    .foregroundStyle(.red)
                            }
                            if report.permissionsOK == false {
                                Label("권한이 0600이 아님", systemImage: "lock.open")
                                    .foregroundStyle(.yellow)
                                Button("수정") { onFixPermissions(report) }
                                    .controlSize(.small)
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

/// 단순 줄바꿈 HStack 대체 — 키가 많으면 여러 줄로.
private struct WrappingHStack<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        // ponytail: FlowLayout 대신 LazyVGrid — 충분히 읽히고 코드가 짧다
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
            content
        }
    }
}
