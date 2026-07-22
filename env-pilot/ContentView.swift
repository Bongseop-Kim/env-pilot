//
//  ContentView.swift
//  env-pilot
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case repository(PersistentIdentifier)
    case history
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query private var workspaces: [Workspace]
    @Query(sort: \Repository.createdAt) private var repositories: [Repository]
    @State private var selection: SidebarItem?
    @State private var showImporter = false
    @State private var showBundleImporter = false
    @State private var bundleData: Data?
    @State private var errorMessage: String?
    @State private var healthByRepo: [String: HealthStatus] = [:]
    @State private var repoPendingDelete: Repository?
    @State private var outputWatchers: [String: OutputFileWatcher] = [:]
    @State private var lastSyncedRevisions: [String: Int] = [:]  // repo별 마지막 sync 시점 콘텐츠 리비전

    private var selectedRepository: Repository? {
        guard case .repository(let id) = selection else { return nil }
        return repositories.first { $0.persistentModelID == id }
    }

    /// SwiftData/CloudKit 변경을 한 번의 값으로 관찰해 활성 로컬 파일을 자동 갱신한다.
    private var syncRevision: Int {
        var hash = Hasher()
        for repo in repositories.sorted(by: { $0.uuid < $1.uuid }) {
            hash.combine(repo.envContentRevision)
        }
        return hash.finalize()
    }

    /// 감시 대상 자체가 바뀔 때만 watcher를 다시 만든다.
    private var watcherRevision: Int {
        var hash = Hasher()
        for repo in repositories.sorted(by: { $0.uuid < $1.uuid }) {
            hash.combine(repo.uuid)
            hash.combine(repo.localPathDisplay)
            for target in (repo.targets ?? []).sorted(by: { $0.relativePath < $1.relativePath }) {
                hash.combine(target.relativePath)
                hash.combine(target.outputPath)
            }
        }
        return hash.finalize()
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Repositories") {
                    ForEach(repositories) { repo in
                        let status = healthByRepo[repo.uuid] ?? .healthy
                        HStack {
                            Label {
                                Text(repo.name)
                            } icon: {
                                Image(systemName: status.iconName)
                                    .foregroundStyle(status.color)
                            }
                            Spacer()
                            Menu {
                                Button("삭제", systemImage: "trash", role: .destructive) {
                                    repoPendingDelete = repo
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.borderless)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("더보기")
                        }
                        .tag(SidebarItem.repository(repo.persistentModelID))
                    }
                }
                Section {
                    Label("History", systemImage: "clock")
                        .tag(SidebarItem.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            // 사이드바 toolbar는 접기/펼치기 후 아이템이 사라지는 macOS 버그가 있어 하단 바로 배치.
            // fileImporter는 같은 뷰에 2개 붙이면 한쪽이 동작하지 않아 버튼별로 분리.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Repository 추가", systemImage: "plus")
                        }
                        .help("프로젝트 폴더를 Repository로 등록")
                        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
                            guard case .success(let url) = result, let workspace = workspaces.first else { return }
                            do {
                                let repo = try RepositoryService.register(
                                    folderURL: url, workspace: workspace, context: context)
                                selection = .repository(repo.persistentModelID)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }

                        Spacer()

                        Button {
                            showBundleImporter = true
                        } label: {
                            Image(systemName: "square.and.arrow.down.on.square")
                        }
                        .help(".envide 번들 가져오기 — 다른 Mac이나 팀원이 내보낸 환경변수 묶음")
                        .fileImporter(isPresented: $showBundleImporter,
                                      allowedContentTypes: [.envide, .json]) { result in
                            guard case .success(let url) = result else { return }
                            let hasAccess = url.startAccessingSecurityScopedResource()
                            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                            do {
                                bundleData = try Data(contentsOf: url)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                }
                .background(.bar)
            }
            .overlay {
                if repositories.isEmpty {
                    ContentUnavailableView {
                        Label("Repository 없음", systemImage: "folder.badge.plus")
                    } description: {
                        Text("프로젝트 폴더를 추가하세요")
                    } actions: {
                        Button("Repository 추가") { showImporter = true }
                    }
                }
            }
            .confirmationDialog(
                "'\(repoPendingDelete?.name ?? "")' Repository를 삭제할까요?",
                isPresented: Binding(presence: $repoPendingDelete), titleVisibility: .visible
            ) {
                Button("삭제", role: .destructive) {
                    if let repo = repoPendingDelete { deleteRepo(repo) }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("Secret을 포함한 모든 변수가 함께 삭제됩니다. 디스크의 파일은 삭제되지 않습니다.")
            }
        } detail: {
            switch selection {
            case .repository:
                if let repo = selectedRepository {
                    RepositoryDetailView(repo: repo)
                        .id(repo.persistentModelID)
                } else {
                    placeholder
                }
            case .history:
                HistoryView()
            case nil:
                placeholder
            }
        }
        .background(ToolbarDisplayModeFixer())
        .sheet(isPresented: Binding(presence: $bundleData)) {
            if let bundleData, let workspace = workspaces.first {
                BundleImportSheet(data: bundleData, workspace: workspace)
            }
        }
        .errorAlert($errorMessage)
        .task { refreshSidebarHealth() }
        .onChange(of: syncRevision, initial: true) {
            syncLocalFiles()
        }
        .onChange(of: watcherRevision, initial: true) {
            restartOutputWatchers()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            env_pilotApp.dedupeAfterSync(context)  // §3.13: CloudKit 병합 후 Workspace 중복 정리
            // ponytail: watcher 재생성은 watcherRevision onChange가 대상 변경 시에만 처리 — 포커스마다 N개 스트림 teardown/rebuild하던 것 제거.
            syncLocalFiles()
            refreshSidebarHealth()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localEnvFileDidChange)) { notification in
            guard let uuid = notification.object as? String,
                  repositories.contains(where: { $0.uuid == uuid }) else { return }
            refreshSidebarHealth()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localSyncConfigurationDidChange)) { _ in
            restartOutputWatchers()
            syncLocalFiles()
            refreshSidebarHealth()
        }
    }

    private var placeholder: some View {
        Text("Repository를 선택하세요").foregroundStyle(SeedColor.fgNeutralMuted)
    }

    /// 사이드바 Health 뱃지 (§3.8: Repository 상태 = 최악 값).
    private func refreshSidebarHealth() {
        for repo in repositories {
            guard let rootURL = RepositoryService.resolveBookmark(repo) else { continue }
            healthByRepo[repo.uuid] = HealthService.overall(
                HealthService.check(repo: repo, rootURL: rootURL))
        }
    }

    private func deleteRepo(_ repo: Repository) {
        if selection == .repository(repo.persistentModelID) { selection = nil }
        LocalSyncService.clearLocalState(for: repo)
        context.delete(repo)
        try? context.save()
    }

    private func syncLocalFiles() {
        // ponytail: 콘텐츠가 바뀐 repo만 reconcile — 변수 1개 편집/포커스 복귀에 전 repo 트리 재순회하던 것 제거.
        // reconcile이 모델을 바꿀 수 있어(adopt/target 발견) 리비전은 실행 후 값으로 저장한다.
        for repo in repositories where lastSyncedRevisions[repo.uuid] != repo.envContentRevision {
            syncLocalFile(for: repo)
            lastSyncedRevisions[repo.uuid] = repo.envContentRevision
        }
    }

    private func syncLocalFile(for repo: Repository) {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        _ = LocalSyncService.reconcile(
            repo: repo,
            rootURL: rootURL,
            context: context
        )
    }

    private func restartOutputWatchers() {
        stopOutputWatchers()
        let modelContext = context
        var watchers: [String: OutputFileWatcher] = [:]
        for repo in repositories {
            guard let rootURL = RepositoryService.resolveBookmark(repo) else { continue }
            let uuid = repo.uuid
            watchers[uuid] = OutputFileWatcher(rootURL: rootURL) {
                _ = LocalSyncService.reconcile(
                    repo: repo,
                    rootURL: rootURL,
                    context: modelContext
                )
                NotificationCenter.default.post(name: .localEnvFileDidChange, object: uuid)
            }
        }
        outputWatchers = watchers
    }

    private func stopOutputWatchers() {
        outputWatchers.values.forEach { $0.stop() }
        outputWatchers.removeAll()
    }
}

private struct EnvFileEditRequest: Identifiable {
    let id = UUID()
    let target: Target?
}

struct RepositoryDetailView: View {
    let repo: Repository
    @Environment(\.modelContext) private var context
    @State private var selectedEnvFilePath = ""
    @State private var showRelinker = false
    @State private var syncError: String?
    @State private var tab: DetailTab = .variables
    @State private var diffs: [ExampleDiffService.Diff] = []
    @State private var drifts: [LocalSyncService.Drift] = []
    @State private var syncIssues: [String] = []
    @State private var hookInstalled: Bool?
    @State private var driftImportPlan: (items: [ImportService.Item], warnings: [String],
                                         missing: [Variable], target: Target)?
    @State private var healthItems: [HealthService.Item] = []
    @State private var safetyReports: [GitSafetyService.Report] = []
    @State private var historyLeaks: [String]?
    @State private var claudeEnvDenied: Bool?
    @State private var agentsRuleInstalled = false
    @State private var pendingAddKey: String?
    @State private var showExport = false
    @State private var envFileEditRequest: EnvFileEditRequest?
    @State private var envFilePendingDelete: Target?

    enum DetailTab { case variables, accounts, health, gitChanges }

    private var isLinked: Bool { RepositoryService.resolveBookmark(repo) != nil }
    private var targets: [Target] { (repo.targets ?? []).sorted { $0.envFilePath < $1.envFilePath } }
    private var selectedTarget: Target? {
        targets.first { $0.envFilePath == selectedEnvFilePath } ?? targets.first
    }
    private var selectedDrift: LocalSyncService.Drift? {
        guard let selectedTarget else { return nil }
        return drifts.first { $0.target.envFilePath == selectedTarget.envFilePath }
    }
    private var selectedIssue: String? {
        guard let selectedTarget else { return nil }
        return syncIssues.first { $0.hasPrefix(selectedTarget.envFilePath + ":") }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            tabContent
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItemGroup {
                AuthGraceBadge()
                Spacer()   // 잠금 배지는 왼쪽, 나머지는 오른쪽 (space-between)
                if tab == .variables, let target = selectedTarget {
                    if targets.count > 1 {
                        Picker("Env 파일", selection: Binding(
                            get: { selectedTarget?.envFilePath ?? "" },
                            set: { selectedEnvFilePath = $0 }
                        )) {
                            ForEach(targets, id: \.envFilePath) { target in
                                Text(target.envFilePath).tag(target.envFilePath)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .help("작업할 .env 파일 선택")
                    } else {
                        Text(target.envFilePath)
                            .fontDesign(.monospaced)
                    }
                }
                if tab == .variables {
                    Menu("Env 파일 관리", systemImage: "doc.badge.gearshape") {
                        Button("새 .env 파일…", systemImage: "plus") {
                            envFileEditRequest = EnvFileEditRequest(target: nil)
                        }
                        if let selectedTarget {
                            Divider()
                            Button("이름/경로 변경…", systemImage: "pencil") {
                                envFileEditRequest = EnvFileEditRequest(target: selectedTarget)
                            }
                            Button("파일 삭제…", systemImage: "trash", role: .destructive) {
                                envFilePendingDelete = selectedTarget
                            }
                        }
                    }
                    .help(".env 파일 생성, 이름/경로 변경 및 삭제")
                }
                Button("백업 및 공유", systemImage: "square.and.arrow.up") { showExport = true }
                    .help(".envide 백업 및 공유")
            }
        }
        .sheet(isPresented: $showExport) {
            if let workspace = repo.workspace {
                ExportSheet(repo: repo, workspace: workspace)
            }
        }
        .sheet(item: $envFileEditRequest) { request in
            EnvFileSheet(repo: repo, target: request.target) { target in
                selectedEnvFilePath = target.envFilePath
                refreshEnvFiles()
            }
        }
        .confirmationDialog(
            "\(envFilePendingDelete?.envFilePath ?? ".env") 파일을 삭제할까요?",
            isPresented: Binding(presence: $envFilePendingDelete), titleVisibility: .visible
        ) {
            Button("파일 삭제", role: .destructive) {
                if let target = envFilePendingDelete { deleteEnvFile(target) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("디스크의 파일과 Env Pilot의 변수·Secret을 함께 삭제합니다. 이 작업은 되돌릴 수 없습니다.")
        }
        .task(id: repo.uuid) {
            refreshDiffs()
            normalizeSelectedFile()
            refreshHealth()
        }
        .onChange(of: repo.envContentRevision) {
            refreshDiffs()
            normalizeSelectedFile()
            refreshHealth()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDiffs()   // git pull 후 앱 전환 시 감지 (§3.6)
            refreshHealth()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localEnvFileDidChange)) { notification in
            guard notification.object as? String == repo.uuid else { return }
            refreshDiffs()
            refreshHealth()
        }
        .sheet(isPresented: Binding(presence: $driftImportPlan), onDismiss: {
            refreshDiffs()
        }) {
            if let plan = driftImportPlan {
                ImportSheet(items: plan.items, warnings: plan.warnings,
                            target: plan.target,
                            newKeysAreSecret: true, missingVariables: plan.missing) {
                    applyPilotValue(for: plan.target)
                }
            }
        }
        .errorAlert($syncError)
        .fileImporter(isPresented: $showRelinker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                try RepositoryService.relink(repo: repo, folderURL: url, context: context)
                NotificationCenter.default.post(name: .localSyncConfigurationDidChange, object: repo.uuid)
            } catch {
                syncError = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .variables:
            if let target = selectedTarget {
                VStack(spacing: 0) {
                    if let drift = selectedDrift {
                        HStack(spacing: SeedSpacing.x2) {
                            StatusLabel(drift.message, systemImage: "exclamationmark.triangle",
                                        tone: .warning)
                            Spacer()
                            Button("동기화…", systemImage: "arrow.triangle.2.circlepath") {
                                tab = .gitChanges
                            }
                            .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                        }
                        .padding(.horizontal, SeedSpacing.x4)
                        .padding(.vertical, SeedSpacing.x2)
                        Divider()
                    } else if let issue = selectedIssue {
                        HStack(spacing: SeedSpacing.x2) {
                            StatusLabel(issue, systemImage: "exclamationmark.triangle", tone: .warning)
                                .lineLimit(1)
                                .help(issue)
                            Spacer()
                            Button("Health에서 확인") { tab = .health }
                                .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                        }
                        .padding(.horizontal, SeedSpacing.x4)
                        .padding(.vertical, SeedSpacing.x2)
                        Divider()
                    }
                    VariablesView(target: target, pendingAddKey: $pendingAddKey)
                        .id(target.persistentModelID)
                }
            } else {
                ContentUnavailableView {
                    Label(".env 파일을 찾지 못했습니다", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("새 파일을 만들거나 프로젝트에 추가된 .env 파일을 다시 찾으세요")
                } actions: {
                    Button("새 .env 파일") {
                        envFileEditRequest = EnvFileEditRequest(target: nil)
                    }
                    Button(".env 파일 다시 찾기", action: refreshEnvFiles)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .accounts:
            CredentialsView(repo: repo)
        case .health:
            HealthView(
                items: healthItems,
                onSelectMissingKey: { filePath, key in
                    selectedEnvFilePath = filePath
                    tab = .variables
                    pendingAddKey = key
                },
                security: securitySections
            )
        case .gitChanges:
            GitChangesView(
                diffs: diffs, drifts: drifts,
                onChanged: { refreshDiffs(); refreshHealth() },
                onImportDrift: { drift in
                    guard let content = drift.fileContent else { return }
                    let plan = ImportService.plan(content: content, target: drift.target,
                                                  environmentName: drift.target.envFilePath)
                    let fileKeys = Set(EnvParser.parse(content).entries.map(\.key))
                    let missing = (drift.target.variables ?? []).filter {
                        $0.environmentName == drift.target.envFilePath
                            && !$0.isIgnored && !fileKeys.contains($0.key)
                    }
                    driftImportPlan = (plan.items, plan.warnings, missing, drift.target)
                },
                onOverwriteDrift: { applyPilotValue(for: $0.target) }
            )
        }
    }

    private var securitySections: SecuritySections {
        SecuritySections(
            safetyReports: safetyReports,
            hookInstalled: hookInstalled,
            historyLeaks: historyLeaks,
            claudeEnvDenied: claudeEnvDenied,
            agentsRuleInstalled: agentsRuleInstalled,
            onAddToGitignore: { fileName in
                guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
                try? GitSafetyService.addToGitignore(line: fileName, rootURL: rootURL)
                refreshHealth()
                refreshDiffs()
            },
            onFixPermissions: { report in
                guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
                let outputURL = rootURL.appendingPathComponent(report.outputRelativePath)
                try? GitSafetyService.fixPermissions(outputURL: outputURL, rootURL: rootURL)
                refreshDiffs()   // 권한 변경 → safetyReports는 reconcile이 갱신
                refreshHealth()
            },
            onInstallHook: { installOrRemoveHook(install: true) },
            onRemoveHook: { installOrRemoveHook(install: false) },
            onAddClaudeDeny: {
                guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
                let fileNames = targets.map(\.outputPath)
                do { try GitSafetyService.addClaudeEnvDenyRules(fileNames: fileNames, rootURL: rootURL) }
                catch { syncError = error.localizedDescription }
                refreshHealth()
            },
            onAddAgentsRule: {
                guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
                do { try GitSafetyService.addAgentsMdEnvRule(rootURL: rootURL) }
                catch { syncError = error.localizedDescription }
                refreshHealth()
            }
        )
    }

    /// §3.19 — pre-commit hook 설치/제거.
    private func installOrRemoveHook(install: Bool) {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        do {
            if install { try GitSafetyService.installHook(rootURL: rootURL) }
            else { try GitSafetyService.removeHook(rootURL: rootURL) }
        } catch {
            syncError = error.localizedDescription
        }
        refreshHealth()
    }

    private func refreshDiffs() {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        let sync = LocalSyncService.reconcile(repo: repo, rootURL: rootURL, context: context)
        drifts = sync.drifts
        syncIssues = sync.issues
        safetyReports = sync.safety  // reconcile이 계산한 것을 재사용 — refreshHealth에서 중복 check 안 함
        diffs = ExampleDiffService.scan(repo: repo, rootURL: rootURL, context: context)
    }

    private func refreshEnvFiles() {
        refreshDiffs()
        normalizeSelectedFile()
        refreshHealth()
        NotificationCenter.default.post(name: .localSyncConfigurationDidChange, object: repo.uuid)
    }

    private func deleteEnvFile(_ target: Target) {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else {
            syncError = "폴더에 접근할 수 없습니다. 경로를 다시 연결하세요."
            return
        }
        let deletedPath = target.envFilePath
        do {
            try EnvFileService.delete(target, rootURL: rootURL, context: context)
            if selectedEnvFilePath == deletedPath { selectedEnvFilePath = "" }
            refreshEnvFiles()
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func applyPilotValue(for target: Target) {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        if let error = LocalSyncService.forceApply(target: target, rootURL: rootURL) {
            syncError = error
        }
        refreshDiffs()
        refreshHealth()
    }

    private func refreshHealth() {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        healthItems = HealthService.check(repo: repo, rootURL: rootURL)
        // safetyReports는 refreshDiffs(reconcile)가 단일 출처. 여기서 재계산하지 않는다.
        claudeEnvDenied = GitSafetyService.claudeEnvDenyStatus(rootURL: rootURL)
        agentsRuleInstalled = GitSafetyService.agentsMdEnvRuleStatus(rootURL: rootURL)
        hookInstalled = GitInfo.gitDirectory(of: rootURL) != nil
            ? GitSafetyService.isHookInstalled(rootURL: rootURL)
            : nil
        // 히스토리 스캔은 pack 전체 inflate라 첫 실행이 느릴 수 있어 백그라운드로.
        // 결과는 fingerprint 캐시되어 이후 호출은 즉시 반환된다.
        Task.detached(priority: .utility) {
            let leaks = GitHistoryScanService.scan(rootURL: rootURL)
            await MainActor.run { historyLeaks = leaks }
        }
    }

    private func normalizeSelectedFile() {
        guard !targets.isEmpty else {
            selectedEnvFilePath = ""
            return
        }
        if !targets.contains(where: { $0.envFilePath == selectedEnvFilePath }) {
            selectedEnvFilePath = targets[0].envFilePath
        }
    }

    /// 탭 점 뱃지 — 열어보지 않아도 문제 여부가 보이게 (최악 심각도 색).
    /// Git 안전성은 SecuritySections와 같은 조건(hookInstalled != nil)일 때만 집계.
    private var tabBadges: [DetailTab: Color] {
        var badges: [DetailTab: Color] = [:]
        let critical = healthItems.contains { $0.status == .critical }
            || safetyReports.contains { !$0.isIgnored || $0.isTracked }
            || historyLeaks?.isEmpty == false
        let warning = healthItems.contains { $0.status == .warning }
            || (hookInstalled != nil && safetyReports.contains { $0.permissionsOK == false })
            || claudeEnvDenied == false || !agentsRuleInstalled
        if critical { badges[.health] = SeedColor.fgCritical }
        else if warning { badges[.health] = SeedColor.fgWarning }
        if !diffs.isEmpty || !drifts.isEmpty { badges[.gitChanges] = SeedColor.fgWarning }
        return badges
    }

    /// env 파일 선택은 윈도우 툴바에 있다. 동기화 액션은 콘텐츠의 diff 배너에 둔다.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isLinked {
                HStack {
                    StatusLabel("이 Mac에서 폴더에 접근할 수 없습니다",
                                systemImage: "exclamationmark.triangle", tone: .warning)
                    Button("폴더 다시 연결…") { showRelinker = true }
                        .buttonStyle(.seed(.neutralWeak, size: .xsmall))
                }
                .padding(.horizontal, SeedSpacing.x4)
                .padding(.top, SeedSpacing.x2_5)
                .padding(.bottom, SeedSpacing.x1)
            }

            SeedTabs(selection: $tab, items: [
                (DetailTab.variables, "Variables", "curlybraces"),
                (DetailTab.accounts, "Accounts", "person.badge.key"),
                (DetailTab.health, "Health", "checkmark.seal"),
                (DetailTab.gitChanges, "Sync", "arrow.triangle.2.circlepath"),
            ], badges: tabBadges)
            .padding(.horizontal, SeedSpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider() }   // 탭 인디케이터가 이 선 위에 겹친다
        }
    }
}

/// 잠금 상태 배지 — 잠김: 자물쇠(클릭 시 인증으로 해제), 해제: 열린 자물쇠 + 남은 초(클릭 시 연장).
/// 아이콘은 항상 표시해 배지가 나타났다 사라지며 툴바가 흔들리는 것을 막는다 (BiometricGate.graceInterval).
struct AuthGraceBadge: View {
    @State private var showExtendConfirm = false

    var body: some View {
        // ponytail: isEnabled 게이트를 TimelineView 밖으로 — 생체인증 미사용 시 매초 리드로우 자체를 없앤다.
        if BiometricGate.isEnabled {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let remaining = Int(BiometricGate.graceRemaining(at: timeline.date).rounded(.up))
                Button {
                    if remaining > 0 {
                        showExtendConfirm = true
                    } else {
                        Task { _ = await BiometricGate.authorize(reason: "Secret 잠금 해제") }
                    }
                } label: {
                    HStack(spacing: SeedSpacing.x1) {
                        Image(systemName: remaining > 0 ? "lock.open.fill" : "lock.fill")
                            .foregroundStyle(remaining > 0 ? SeedColor.fgPositive : SeedColor.fgNeutralMuted)
                        if remaining > 0 {
                            Text("\(remaining)초")
                                .monospacedDigit()
                                .foregroundStyle(SeedColor.fgPositive)
                        }
                    }
                }
                .help(remaining > 0
                      ? "잠금 해제됨 — \(remaining)초 동안 비밀번호 확인 없이 Secret을 표시·복사할 수 있습니다. 클릭하면 1분으로 초기화"
                      : "잠금 상태 — 클릭해서 잠금 해제")
            }
            .alert("잠금 해제 시간을 다시 1분으로 초기화할까요?", isPresented: $showExtendConfirm) {
            Button("초기화") { BiometricGate.extendGrace() }
            Button("취소", role: .cancel) {}
            } message: {
                Text("남은 시간과 관계없이 지금부터 다시 \(Int(BiometricGate.graceInterval))초 동안 비밀번호 확인 없이 Secret을 표시·복사할 수 있습니다.")
            }
        }
    }
}

/// SwiftUI에 노출되지 않은 NSToolbar 설정 — 표시 방식을 icon only로 고정하고
/// 툴바 우클릭의 "아이콘만 보기/아이콘 및 텍스트" 선택 메뉴를 없앤다.
struct ToolbarDisplayModeFixer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let toolbar = nsView.window?.toolbar else { return }
            toolbar.displayMode = .iconOnly
            toolbar.allowsDisplayModeCustomization = false
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Workspace.self, HistoryEntry.self], inMemory: true)
}
