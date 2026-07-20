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

    private var environmentNames: [String] {
        (workspaces.first?.environments ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.name)
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
                                Text(status.symbol).font(.caption2)
                            }
                        }
                        .tag(SidebarItem.repository(repo.persistentModelID))
                        .contextMenu {
                            Button("삭제", role: .destructive) { deleteRepo(repo) }
                        }
                    }
                }
                Section {
                    Label("History", systemImage: "clock")
                        .tag(SidebarItem.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                Button("Repository 추가", systemImage: "plus") { showImporter = true }
                Button(".envide 가져오기", systemImage: "square.and.arrow.down.on.square") {
                    showBundleImporter = true
                }
                .help(".envide 번들 가져오기 (§3.14)")
            }
            .overlay {
                if repositories.isEmpty {
                    ContentUnavailableView(
                        "Repository 없음",
                        systemImage: "folder.badge.plus",
                        description: Text("+ 버튼으로 프로젝트 폴더를 추가하세요")
                    )
                }
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
            // 전역 Environment 셀렉터 (PRD §4.2) — 전환 시 모든 화면이 해당 환경 기준
            ToolbarItem(placement: .primaryAction) {
                Picker("Environment", selection: $selectedEnvironment) {
                    ForEach(environmentNames, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result, let workspace = workspaces.first else { return }
            do {
                let repo = try RepositoryService.register(folderURL: url, workspace: workspace, context: context)
                selection = .repository(repo.persistentModelID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showBundleImporter, allowedContentTypes: [.envide, .json]) { result in
            guard case .success(let url) = result else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                bundleData = try Data(contentsOf: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: .constant(bundleData != nil), onDismiss: { bundleData = nil }) {
            if let bundleData, let workspace = workspaces.first {
                BundleImportSheet(data: bundleData, workspace: workspace)
            }
        }
        .alert("오류", isPresented: .constant(errorMessage != nil)) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { refreshSidebarHealth() }
        .onChange(of: environmentNames, initial: true) {
            // Settings에서 Environment 삭제 시 선택값 폴백
            if !environmentNames.isEmpty && !environmentNames.contains(selectedEnvironment) {
                selectedEnvironment = environmentNames.first!
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            env_pilotApp.dedupeAfterSync(context)  // §3.13: CloudKit 병합 후 Workspace 중복 정리
            refreshSidebarHealth()
        }
    }

    private var placeholder: some View {
        Text("Repository를 선택하세요").foregroundStyle(.secondary)
    }

    /// 사이드바 Health 뱃지 (§3.8: Repository 상태 = 최악 값).
    private func refreshSidebarHealth() {
        for repo in repositories {
            guard let rootURL = RepositoryService.resolveBookmark(repo) else { continue }
            healthByRepo[repo.uuid] = HealthService.overall(
                HealthService.check(repo: repo, rootURL: rootURL, environmentNames: environmentNames))
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
    @State private var healthItems: [HealthService.Item] = []
    @State private var safetyReports: [GitSafetyService.Report] = []
    @State private var scanCandidates: [MonorepoScanner.Candidate]?
    @State private var pendingAddKey: String?
    @State private var showExport = false

    enum DetailTab { case variables, compare, health, gitChanges }

    private var isLinked: Bool { RepositoryService.resolveBookmark(repo) != nil }
    private var targets: [Target] { (repo.targets ?? []).sorted { $0.relativePath < $1.relativePath } }
    private var selectedTarget: Target? {
        targets.first { $0.relativePath == selectedTargetPath } ?? targets.first
    }
    private var diffCount: Int { diffs.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabContent
        }
        .navigationTitle(repo.name)
        .navigationSubtitle("\(selectedTargetPath) · \(environmentName)")
        .toolbar {
            Button("Scan", systemImage: "arrow.trianglehead.2.clockwise") { scanMonorepo(auto: false) }
                .help("Monorepo Target 탐색 및 example 변경 감지")
            Button("Generate", systemImage: "square.and.arrow.down") { prepareGenerate() }
                .help("\(environmentName) 기준으로 .env 파일 생성")
            Button("Export", systemImage: "square.and.arrow.up") { showExport = true }
                .help(".envide 번들로 내보내기 (§3.14)")
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
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDiffs()   // git pull 후 앱 전환 시 감지 (§3.6)
            refreshHealth()
        }
        .sheet(isPresented: .constant(scanCandidates != nil), onDismiss: { scanCandidates = nil }) {
            if let candidates = scanCandidates {
                TargetScanSheet(repo: repo, candidates: candidates) {
                    scanCandidates = nil
                    refreshDiffs()
                }
            }
        }
        .sheet(isPresented: .constant(generatePlans != nil), onDismiss: {
            generatePlans = nil
            refreshHealth()
        }) {
            if let plans = generatePlans, let rootURL = generateRootURL {
                GenerateSheet(repo: repo, plans: plans, rootURL: rootURL, environmentName: environmentName)
            }
        }
        .alert("오류", isPresented: .constant(generateError != nil)) {
            Button("확인") { generateError = nil }
        } message: {
            Text(generateError ?? "")
        }
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
                Text("Target이 없습니다").foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            }
        case .compare:
            if let target = selectedTarget {
                CompareView(target: target, environmentNames: environmentNames)
                    .id(target.persistentModelID)
            } else {
                Text("Target이 없습니다").foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            }
        case .health:
            HealthView(
                items: healthItems,
                safetyReports: safetyReports,
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
                }
            )
        case .gitChanges:
            GitChangesView(diffs: diffs, environmentNames: environmentNames,
                           onChanged: { refreshDiffs(); refreshHealth() })
        }
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
    }

    private func refreshHealth() {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        healthItems = HealthService.check(repo: repo, rootURL: rootURL, environmentNames: environmentNames)
        safetyReports = GitSafetyService.check(repo: repo, rootURL: rootURL)
    }

    /// Monorepo 스캔: 기존 Target을 제외한 신규 후보만 시트로 제안 (§3.5).
    private func scanMonorepo(auto: Bool) {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else {
            if !auto { generateError = "폴더에 접근할 수 없습니다. 경로를 다시 연결하세요." }
            return
        }
        let existingPaths = Set(targets.map(\.relativePath))
        let newCandidates = MonorepoScanner.scan(rootURL: rootURL)
            .filter { !existingPaths.contains($0.relativePath) }
        if !newCandidates.isEmpty {
            scanCandidates = newCandidates
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
                    Label("이 Mac에서 폴더에 접근할 수 없습니다", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("폴더 다시 연결…") { showRelinker = true }
                }
            }
            HStack {
                Picker("", selection: $tab) {
                    Text("Variables").tag(DetailTab.variables)
                    Text("Compare").tag(DetailTab.compare)
                    Text("Health").tag(DetailTab.health)
                    Text(diffCount > 0 ? "Git Changes (\(diffCount))" : "Git Changes")
                        .tag(DetailTab.gitChanges)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                if (tab == .variables || tab == .compare) && targets.count > 1 {
                    Picker("Target", selection: $selectedTargetPath) {
                        ForEach(targets, id: \.relativePath) { Text($0.relativePath).tag($0.relativePath) }
                    }
                    .fixedSize()
                }
                Spacer()
                Text(repo.gitRemoteURL ?? repo.localPathDisplay ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
