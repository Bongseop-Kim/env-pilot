import SwiftUI

/// Security 탭 — secret 노출 방지.
/// Git Safety(§3.11, 현재 상태) + Git 히스토리(과거 노출) + pre-commit hook(§3.19) + AI 에이전트.
struct SecurityView: View {
    let safetyReports: [GitSafetyService.Report]
    let hookInstalled: Bool?   // nil = Git 저장소 아님 → Git 섹션 전체 숨김
    let historyLeaks: [String]? // Git 히스토리에서 발견된 .env 파일명. nil = 비Git 또는 스캔 중
    let claudeEnvDenied: Bool? // nil = .claude 설정 없음 → Claude 행 숨김
    let agentsRuleInstalled: Bool // AGENTS.md 공통 규칙 — 모든 에이전트 대상이라 항상 표시
    let onAddToGitignore: (_ fileName: String) -> Void
    let onFixPermissions: (_ report: GitSafetyService.Report) -> Void
    let onInstallHook: () -> Void
    let onRemoveHook: () -> Void
    let onAddClaudeDeny: () -> Void
    let onAddAgentsRule: () -> Void

    var body: some View {
        List {
            if hookInstalled != nil {
                safetySection
                historySection
                hookSection
            }
            agentSection
        }
    }

    /// 현재 상태 검사: .gitignore 등재 여부, 현재 커밋(tracked) 여부, 파일 권한(0600).
    @ViewBuilder private var safetySection: some View {
        let issues = safetyReports.filter(\.hasIssue)
        Section("Git Safety") {
            if issues.isEmpty {
                Label("모든 env 파일이 .gitignore에 있고 커밋되어 있지 않습니다",
                      systemImage: "checkmark.shield.fill")
                    .foregroundStyle(SeedColor.fgPositive)
                    .seedListRow()
            } else {
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
                                Label("현재 Git이 추적 중 — git rm --cached로 해제 필요",
                                      systemImage: "xmark.octagon.fill")
                                    .foregroundStyle(SeedColor.fgCritical)
                            }
                            if report.permissionsOK == false {
                                Label("권한이 0600이 아님", systemImage: "lock.open")
                                    .foregroundStyle(SeedColor.fgWarning)
                                Button("수정") { onFixPermissions(report) }
                                    .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                            }
                        }
                        .font(SeedTypography.body)
                    }
                    .seedListRow()
                }
            }
        }
    }

    /// Git 히스토리에 커밋된 적 있는 .env — git rm으로 지워지지 않는 과거 노출 감지.
    /// Git Safety의 "추적 중"(현재)과 별개 축: 지금 지워도 과거 커밋에는 남는다.
    @ViewBuilder private var historySection: some View {
        if let historyLeaks {
            Section("Git 히스토리") {
                if historyLeaks.isEmpty {
                    Label("Git 히스토리에서 .env 흔적이 발견되지 않았습니다",
                          systemImage: "checkmark.shield.fill")
                        .foregroundStyle(SeedColor.fgPositive)
                        .seedListRow()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("과거 커밋에 남아 있음: \(historyLeaks.joined(separator: ", "))",
                              systemImage: "xmark.octagon.fill")
                            .foregroundStyle(SeedColor.fgCritical)
                        HStack {
                            Text("git rm으로는 지워지지 않습니다. 히스토리에서 제거하고 노출된 키를 로테이션하세요.")
                                .font(SeedTypography.body)
                                .foregroundStyle(SeedColor.fgNeutralMuted)
                            Button("정리 명령 복사") {
                                ClipboardService.copy(Self.cleanupCommand(historyLeaks),
                                                      clearAfterDelay: false)
                            }
                            .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                            .help("git filter-repo로 히스토리에서 해당 파일을 제거하는 명령을 복사합니다")
                        }
                    }
                    .seedListRow()
                }
            }
        }
    }

    /// 모든 깊이의 해당 파일명을 히스토리에서 제거 (fnmatch의 *는 /도 매칭).
    static func cleanupCommand(_ names: [String]) -> String {
        let globs = names.flatMap { ["--path-glob '\($0)'", "--path-glob '*/\($0)'"] }
        return "git filter-repo --invert-paths \(globs.joined(separator: " ")) --force"
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
                .seedListRow()
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
            .seedListRow()
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
                .seedListRow()
            }
        }
    }
}
