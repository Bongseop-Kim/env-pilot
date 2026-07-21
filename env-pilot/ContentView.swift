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
    @AppStorage("selectedEnvironment") private var selectedEnvironment = "Local"
    @State private var selection: SidebarItem?
    @State private var showImporter = false
    @State private var showBundleImporter = false
    @State private var bundleData: Data?
    @State private var errorMessage: String?
    @State private var healthByRepo: [String: HealthStatus] = [:]
    @State private var repoPendingDelete: Repository?
    @State private var showEnvironmentsEditor = false

    // Environment는 Repository 소속 — 선택된 repo의 목록 기준
    private var environmentNames: [String] {
        selectedRepository?.environmentNames ?? []
    }

    private var selectedRepository: Repository? {
        guard case .repository(let id) = selection else { return nil }
        return repositories.first { $0.persistentModelID == id }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Repositories") {
                    ForEach(repositories) { repo in
                        HStack {
                            Label(repo.name, systemImage: "folder")
                            Spacer()
                            if let status = healthByRepo[repo.uuid], status != .healthy {
                                Image(systemName: status.iconName)
                                    .foregroundStyle(status.color)
                                    .font(.caption)
                            }
                        }
                        .tag(SidebarItem.repository(repo.persistentModelID))
                        .contextMenu {
                            Button("삭제", role: .destructive) { repoPendingDelete = repo }
                        }
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
                    RepositoryDetailView(repo: repo, environmentName: selectedEnvironment,
                                         environmentNames: environmentNames)
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
        .toolbar {
            // Environment 셀렉터 (PRD §4.2) — 선택된 Repository의 환경 목록 기준
            ToolbarItem(placement: .primaryAction) {
                if selectedRepository != nil {
                    HStack(spacing: 4) {
                        if !environmentNames.isEmpty {
                            Picker("Environment", selection: $selectedEnvironment) {
                                ForEach(environmentNames, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .help("Environment 전환 — Variables/Health/Generate가 이 환경 기준으로 동작합니다")
                        }
                        Button("Environment 편집", systemImage: "slider.horizontal.3") {
                            showEnvironmentsEditor = true
                        }
                        .labelStyle(.iconOnly)
                        .help("이 Repository의 Environment 목록 편집 (추가/삭제/순서)")
                    }
                }
            }
        }
        .sheet(isPresented: $showEnvironmentsEditor) {
            if let repo = selectedRepository {
                EnvironmentsEditor(repo: repo)
            }
        }
        .sheet(isPresented: Binding(presence: $bundleData)) {
            if let bundleData, let workspace = workspaces.first {
                BundleImportSheet(data: bundleData, workspace: workspace)
            }
        }
        .errorAlert($errorMessage)
        .task { refreshSidebarHealth() }
        .onChange(of: environmentNames, initial: true) {
            // Repository 전환·Environment 삭제 시 선택값 폴백
            if !environmentNames.isEmpty && !environmentNames.contains(selectedEnvironment) {
                selectedEnvironment = environmentNames.first!
            }
            refreshSidebarHealth()   // Environment 추가/삭제 즉시 사이드바 뱃지 반영
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            env_pilotApp.dedupeAfterSync(context)  // §3.13: CloudKit 병합 후 Workspace 중복 정리
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
                HealthService.check(repo: repo, rootURL: rootURL, environmentNames: repo.environmentNames))
        }
    }

    private func deleteRepo(_ repo: Repository) {
        if selection == .repository(repo.persistentModelID) { selection = nil }
        context.delete(repo)
        try? context.save()
    }
}

struct RepositoryDetailView: View {
    let repo: Repository
    let environmentName: String
    let environmentNames: [String]
    @Environment(\.modelContext) private var context
    @AppStorage("selectedEnvironment") private var selectedEnvironment = "Local"
    @State private var selectedTargetPath: String = "."
    @State private var showRelinker = false
    @State private var generatePlans: [GenerateService.Plan]?
    @State private var generateRootURL: URL?
    @State private var generateError: String?
    @State private var tab: DetailTab = .variables
    @State private var diffs: [ExampleDiffService.Diff] = []
    @State private var drifts: [GenerateService.Drift] = []
    @State private var hookInstalled: Bool?
    @State private var driftImportPlan: (items: [ImportService.Item], warnings: [String], target: Target)?
    @State private var healthItems: [HealthService.Item] = []
    @State private var safetyReports: [GitSafetyService.Report] = []
    @State private var claudeEnvDenied: Bool?
    @State private var agentsRuleInstalled = false
    @State private var scanCandidates: [MonorepoScanner.Candidate]?
    @State private var pendingAddKey: String?
    @State private var showExport = false

    enum DetailTab { case variables, accounts, compare, health, gitChanges }

    private var isLinked: Bool { RepositoryService.resolveBookmark(repo) != nil }
    private var targets: [Target] { (repo.targets ?? []).sorted { $0.relativePath < $1.relativePath } }
    private var selectedTarget: Target? {
        targets.first { $0.relativePath == selectedTargetPath } ?? targets.first
    }
    private var diffCount: Int { diffs.reduce(0) { $0 + $1.count } + drifts.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            SeedDivider()
            tabContent
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .toolbar {
            Button("Scan", systemImage: "arrow.trianglehead.2.clockwise") { scanMonorepo(auto: false) }
                .help("Scan — Monorepo Target 탐색 및 .env.example 변경 감지 (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            Button("Generate", systemImage: "doc.badge.plus") { prepareGenerate() }
                .help("Generate — \(environmentName) 환경 기준으로 .env 파일 생성 (⌘G)")
                .keyboardShortcut("g", modifiers: .command)
            Button("Export", systemImage: "square.and.arrow.up") { showExport = true }
                .help("Export — .envide 번들로 내보내기 (다른 Mac·팀원과 공유)")
        }
        .sheet(isPresented: $showExport) {
            if let workspace = repo.workspace {
                ExportSheet(repo: repo, workspace: workspace)
            }
        }
        .task(id: repo.uuid) {
            refreshDiffs()
            refreshHealth()
            autoScanIfFirstVisit()
        }
        .onChange(of: environmentNames) {
            refreshHealth()   // Environment 추가/삭제 즉시 Health 탭 반영
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDiffs()   // git pull 후 앱 전환 시 감지 (§3.6)
            refreshHealth()
        }
        .sheet(isPresented: Binding(presence: $scanCandidates), onDismiss: {
            refreshDiffs()
        }) {
            if let candidates = scanCandidates {
                TargetScanSheet(repo: repo, candidates: candidates)
            }
        }
        .sheet(isPresented: Binding(presence: $driftImportPlan), onDismiss: {
            refreshDiffs()
        }) {
            if let plan = driftImportPlan {
                ImportSheet(items: plan.items, warnings: plan.warnings,
                            target: plan.target, environmentName: environmentName)
            }
        }
        .sheet(isPresented: Binding(presence: $generatePlans), onDismiss: {
            refreshHealth()
            refreshDiffs()   // Generate 후 drift 기준점 갱신 반영 (§3.18)
        }) {
            if let plans = generatePlans, let rootURL = generateRootURL {
                GenerateSheet(repo: repo, plans: plans, rootURL: rootURL, environmentName: environmentName)
            }
        }
        .errorAlert($generateError)
        .fileImporter(isPresented: $showRelinker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            try? RepositoryService.relink(repo: repo, folderURL: url, context: context)
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .variables:
            if let target = selectedTarget {
                VariablesView(target: target, environmentName: environmentName,
                              pendingAddKey: $pendingAddKey)
                    .id("\(target.persistentModelID)-\(environmentName)")
            } else {
                Text("Target이 없습니다").foregroundStyle(SeedColor.fgNeutralMuted)
                    .frame(maxHeight: .infinity)
            }
        case .accounts:
            CredentialsView(repo: repo)
        case .compare:
            if let target = selectedTarget {
                CompareView(target: target, environmentNames: environmentNames)
                    .id(target.persistentModelID)
            } else {
                Text("Target이 없습니다").foregroundStyle(SeedColor.fgNeutralMuted)
                    .frame(maxHeight: .infinity)
            }
        case .health:
            HealthView(
                items: healthItems,
                safetyReports: safetyReports,
                hookInstalled: hookInstalled,
                claudeEnvDenied: claudeEnvDenied,
                agentsRuleInstalled: agentsRuleInstalled,
                onSelectMissingKey: { targetPath, environment, key in
                    // 누락 키 클릭 → 해당 Variable 입력으로 이동 (§3.8 수용 기준)
                    selectedTargetPath = targetPath
                    selectedEnvironment = environment
                    tab = .variables
                    pendingAddKey = key
                },
                onAddToGitignore: { fileName in
                    guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
                    try? GitSafetyService.addToGitignore(line: fileName, rootURL: rootURL)
                    refreshHealth()
                },
                onFixPermissions: { report in
                    guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
                    let outputURL = rootURL.appendingPathComponent(report.outputRelativePath)
                    try? GitSafetyService.fixPermissions(outputURL: outputURL, rootURL: rootURL)
                    refreshHealth()
                },
                onInstallHook: { installOrRemoveHook(install: true) },
                onRemoveHook: { installOrRemoveHook(install: false) },
                onAddClaudeDeny: {
                    guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
                    let fileNames = targets.map(\.outputPath)
                    do { try GitSafetyService.addClaudeEnvDenyRules(fileNames: fileNames, rootURL: rootURL) }
                    catch { generateError = error.localizedDescription }
                    refreshHealth()
                },
                onAddAgentsRule: {
                    guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
                    do { try GitSafetyService.addAgentsMdEnvRule(rootURL: rootURL) }
                    catch { generateError = error.localizedDescription }
                    refreshHealth()
                }
            )
        case .gitChanges:
            GitChangesView(
                diffs: diffs, drifts: drifts, environmentNames: environmentNames,
                onChanged: { refreshDiffs(); refreshHealth() },
                onImportDrift: { drift in
                    // §3.18 가져오기 — 현재 파일을 기준점으로 인정하고 §3.12 임포트 플로우
                    guard let content = drift.fileContent else { return }
                    drift.target.outputHash = GenerateService.sha256(content)
                    try? context.save()
                    let plan = ImportService.plan(content: content, target: drift.target,
                                                  environmentName: environmentName)
                    driftImportPlan = (plan.items, plan.warnings, drift.target)
                    refreshDiffs()
                },
                onOverwriteDrift: { _ in prepareGenerate() },  // §3.4 재생성 플로우 재사용
                onIgnoreDrift: { drift in
                    drift.target.outputHash = drift.fileContent.map { GenerateService.sha256($0) }
                    try? context.save()
                    refreshDiffs()
                }
            )
        }
    }

    /// §3.19 — pre-commit hook 설치/제거.
    private func installOrRemoveHook(install: Bool) {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        do {
            if install { try GitSafetyService.installHook(rootURL: rootURL) }
            else { try GitSafetyService.removeHook(rootURL: rootURL) }
        } catch {
            generateError = error.localizedDescription
        }
        refreshHealth()
    }

    private func prepareGenerate() {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else {
            generateError = "폴더에 접근할 수 없습니다. 경로를 다시 연결하세요."
            return
        }
        generateRootURL = rootURL
        generatePlans = GenerateService.makePlans(repo: repo, rootURL: rootURL, environmentName: environmentName)
    }

    private func refreshDiffs() {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        diffs = ExampleDiffService.scan(repo: repo, rootURL: rootURL, context: context)
        drifts = GenerateService.checkDrift(repo: repo, rootURL: rootURL)  // §3.18 — §3.6과 동일 시점
    }

    private func refreshHealth() {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        healthItems = HealthService.check(repo: repo, rootURL: rootURL, environmentNames: environmentNames)
        safetyReports = GitSafetyService.check(repo: repo, rootURL: rootURL)
        claudeEnvDenied = GitSafetyService.claudeEnvDenyStatus(rootURL: rootURL)
        agentsRuleInstalled = GitSafetyService.agentsMdEnvRuleStatus(rootURL: rootURL)
        hookInstalled = GitInfo.gitDirectory(of: rootURL) != nil
            ? GitSafetyService.isHookInstalled(rootURL: rootURL)
            : nil
    }

    /// Monorepo 스캔: 기존 Target을 제외한 신규 후보만 시트로 제안 (§3.5).
    private func scanMonorepo(auto: Bool) {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else {
            if !auto { generateError = "폴더에 접근할 수 없습니다. 경로를 다시 연결하세요." }
            return
        }
        let existingPaths = Set(targets.map(\.relativePath))
        let candidates = MonorepoScanner.scan(rootURL: rootURL)
        // 이미 등록된 Target도 시트에 "추가됨"으로 표시 — 신규 후보가 있을 때만 시트를 띄운다
        if candidates.contains(where: { !existingPaths.contains($0.relativePath) }) {
            scanCandidates = candidates
        } else if !auto {
            generateError = "새로운 Monorepo Target 후보가 없습니다."
        }
    }

    /// Repository 등록 직후 첫 방문 시 1회 자동 스캔 (§3.5 "등록 시").
    private func autoScanIfFirstVisit() {
        let key = "monorepoScanned.\(repo.uuid)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        scanMonorepo(auto: true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isLinked {
                HStack {
                    StatusLabel("이 Mac에서 폴더에 접근할 수 없습니다",
                                systemImage: "exclamationmark.triangle", tone: .warning)
                    Button("폴더 다시 연결…") { showRelinker = true }
                }
            }
            HStack {
                SeedTabs(selection: $tab, items: [
                    (DetailTab.variables, "Variables"),
                    (DetailTab.accounts, "Accounts"),
                    (DetailTab.compare, "Compare"),
                    (DetailTab.health, "Health"),
                    (DetailTab.gitChanges, "Git Changes"),
                ])
                .fixedSize()

                // 라벨에 숫자를 넣으면 segmented control 폭이 흔들려 별도 뱃지로 표시
                if diffCount > 0 {
                    SeedBadge("\(diffCount)", tone: .brand)
                        .help("처리 대기 중인 Git 변경 \(diffCount)건")
                }

                if (tab == .variables || tab == .compare) && targets.count > 1 {
                    Picker("Target", selection: $selectedTargetPath) {
                        ForEach(targets, id: \.relativePath) { Text($0.relativePath).tag($0.relativePath) }
                    }
                    .fixedSize()
                }
                Spacer()
                Text(repo.gitRemoteURL ?? repo.localPathDisplay ?? "")
                    .font(.caption)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Workspace.self, HistoryEntry.self], inMemory: true)
}
