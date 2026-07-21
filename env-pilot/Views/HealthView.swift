import SwiftUI

extension HealthStatus {
    var seedTone: SeedTone {
        switch self {
        case .healthy: .positive
        case .warning: .warning
        case .critical: .critical
        }
    }

    var color: Color { seedTone.fg }
}

/// Health 탭 (PRD §3.8) — Target × Environment 판정 상세 + Git Safety 이슈 + pre-commit hook (§3.19).
struct HealthView: View {
    let items: [HealthService.Item]
    let safetyReports: [GitSafetyService.Report]
    let hookInstalled: Bool?   // nil = Git 저장소 아님 → hook 섹션 숨김
    let claudeEnvDenied: Bool? // nil = .claude 설정 없음 → Claude 행 숨김
    let agentsRuleInstalled: Bool // AGENTS.md 공통 규칙 — 모든 에이전트 대상이라 항상 표시
    let onSelectMissingKey: (_ targetPath: String, _ environmentName: String, _ key: String) -> Void
    let onAddToGitignore: (_ fileName: String) -> Void
    let onFixPermissions: (_ report: GitSafetyService.Report) -> Void
    let onInstallHook: () -> Void
    let onRemoveHook: () -> Void
    let onAddClaudeDeny: () -> Void
    let onAddAgentsRule: () -> Void

    private var allHealthy: Bool {
        items.allSatisfy { $0.status == .healthy } && !safetyReports.contains(where: \.hasIssue)
    }

    var body: some View {
        if items.isEmpty && safetyReports.allSatisfy({ !$0.hasIssue }) && hookInstalled == nil
            && claudeEnvDenied == nil && agentsRuleInstalled {
            ContentUnavailableView("판정 대상 없음", systemImage: "questionmark.circle",
                                   description: Text(".env.example이 있는 Target이 없습니다"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // 상단 정렬 VStack 안에서 중앙 배치
        } else {
            List {
                if allHealthy {
                    Label("All Healthy — 모든 Environment가 example 키를 충족합니다",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(SeedColor.fgPositive)
                } else {
                    healthSections
                    safetySection
                }
                hookSection
                agentSection
            }
        }
    }

    /// AI 에이전트 노출 — .env 읽기 차단 (1Password zero-exposure 참고).
    /// AGENTS.md는 모든 에이전트 공통(지시), Claude Code는 permissions.deny(강제).
    @ViewBuilder private var agentSection: some View {
        Section("AI 에이전트") {
            HStack {
                Label(agentsRuleInstalled
                      ? "AGENTS.md — 모든 에이전트에 .env 읽기 금지 규칙이 있습니다"
                      : "AGENTS.md에 .env 읽기 금지 규칙이 없습니다 (Codex·Cursor 등 공통)",
                      systemImage: agentsRuleInstalled ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(agentsRuleInstalled ? SeedColor.fgPositive : SeedColor.fgWarning)
                Spacer()
                if !agentsRuleInstalled {
                    Button("AGENTS.md에 규칙 추가") { onAddAgentsRule() }
                        .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                        .help("AGENTS.md에 .env 파일을 읽지 말라는 공통 규칙 블록을 추가합니다")
                }
            }
            if let claudeEnvDenied {
                HStack {
                    Label(claudeEnvDenied
                          ? "차단됨 — Claude Code가 .env 파일을 읽을 수 없습니다"
                          : "Claude Code 설정이 있지만 .env 파일 읽기가 차단되지 않았습니다",
                          systemImage: claudeEnvDenied ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(claudeEnvDenied ? SeedColor.fgPositive : SeedColor.fgWarning)
                    Spacer()
                    if !claudeEnvDenied {
                        Button("읽기 차단 규칙 추가") { onAddClaudeDeny() }
                            .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                            .help(".claude/settings.local.json의 permissions.deny에 출력 파일 차단 규칙을 추가합니다")
                    }
                }
            }
        }
    }

    /// §3.19 — 스테이징된 .env 파일 커밋을 차단하는 pre-commit hook 설치/제거.
    @ViewBuilder private var hookSection: some View {
        if let hookInstalled {
            Section("pre-commit Hook") {
                HStack {
                    Label(hookInstalled
                          ? "설치됨 — .env 파일 커밋이 차단됩니다"
                          : ".env 파일 커밋을 차단하는 hook을 설치할 수 있습니다",
                          systemImage: hookInstalled ? "checkmark.shield.fill" : "shield")
                        .foregroundStyle(hookInstalled ? SeedColor.fgPositive : SeedColor.fgNeutralMuted)
                    Spacer()
                    Button(hookInstalled ? "제거" : "pre-commit hook 설치") {
                        hookInstalled ? onRemoveHook() : onInstallHook()
                    }
                    .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                }
            }
        }
    }

    @ViewBuilder private var healthSections: some View {
        let grouped = Dictionary(grouping: items, by: \.targetPath)
        let targetPaths = grouped.keys.sorted()
        ForEach(targetPaths, id: \.self) { targetPath in
            if targetPaths.count == 1 {
                healthRows(grouped[targetPath] ?? [])
            } else {
                Section(targetPath == "." ? "Root" : targetPath) {
                    healthRows(grouped[targetPath] ?? [])
                }
            }
        }
    }

    @ViewBuilder private func healthRows(_ items: [HealthService.Item]) -> some View {
        ForEach(items) { item in
            HStack(alignment: .top) {
                Image(systemName: item.status.iconName)
                    .foregroundStyle(item.status.color)
                Text(item.environmentName).frame(width: 110, alignment: .leading)
                keyChips(item)
                Spacer()
            }
        }
    }

    @ViewBuilder private func keyChips(_ item: HealthService.Item) -> some View {
        if item.status == .healthy {
            Text("Healthy").foregroundStyle(SeedColor.fgNeutralMuted).font(.caption)
        } else {
            // 누락 키 클릭 → 해당 Variable 입력으로 이동 (§3.8 수용 기준)
            WrappingHStack {
                ForEach(item.missingKeys, id: \.self) { key in
                    Button {
                        onSelectMissingKey(item.targetPath, item.environmentName, key)
                    } label: {
                        SeedBadge("\(key) 누락", tone: .critical)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(item.emptyValueKeys, id: \.self) { key in
                    Button {
                        onSelectMissingKey(item.targetPath, item.environmentName, key)
                    } label: {
                        SeedBadge("\(key) 빈 값", tone: .warning)
                    }
                    .buttonStyle(.plain)
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
                                    .foregroundStyle(SeedColor.fgCritical)
                                Button(".gitignore에 추가") {
                                    onAddToGitignore((report.outputRelativePath as NSString).lastPathComponent)
                                }
                                .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                            }
                            if report.isTracked {
                                Label("Git에 커밋되어 있음 — git rm --cached로 제거 필요", systemImage: "xmark.octagon.fill")
                                    .foregroundStyle(SeedColor.fgCritical)
                            }
                            if report.permissionsOK == false {
                                Label("권한이 0600이 아님", systemImage: "lock.open")
                                    .foregroundStyle(SeedColor.fgWarning)
                                Button("수정") { onFixPermissions(report) }
                                    .buttonStyle(.seed(.neutralWeak, size: .xsmall))
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
