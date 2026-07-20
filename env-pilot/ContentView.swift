//
//  ContentView.swift
//  env-pilot
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query private var workspaces: [Workspace]
    @Query(sort: \Repository.createdAt) private var repositories: [Repository]
    @AppStorage("selectedEnvironment") private var selectedEnvironment = "Local"
    @State private var selection: Repository?
    @State private var showImporter = false
    @State private var errorMessage: String?

    private var environmentNames: [String] {
        (workspaces.first?.environments ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.name)
    }

    var body: some View {
        NavigationSplitView {
            List(repositories, selection: $selection) { repo in
                Label(repo.name, systemImage: "folder")
                    .tag(repo)
                    .contextMenu {
                        Button("삭제", role: .destructive) { deleteRepo(repo) }
                    }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                Button("Repository 추가", systemImage: "plus") { showImporter = true }
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
            if let repo = selection {
                RepositoryDetailView(repo: repo, environmentName: selectedEnvironment)
                    .id(repo.persistentModelID)  // repo 전환 시 상태 초기화
            } else {
                Text("Repository를 선택하세요")
                    .foregroundStyle(.secondary)
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
                selection = try RepositoryService.register(folderURL: url, workspace: workspace, context: context)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("오류", isPresented: .constant(errorMessage != nil)) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func deleteRepo(_ repo: Repository) {
        if selection == repo { selection = nil }
        context.delete(repo)
        try? context.save()
    }
}

struct RepositoryDetailView: View {
    let repo: Repository
    let environmentName: String
    @Environment(\.modelContext) private var context
    @State private var selectedTargetPath: String = "."
    @State private var showRelinker = false
    @State private var generatePlans: [GenerateService.Plan]?
    @State private var generateRootURL: URL?
    @State private var generateError: String?
    @State private var tab: DetailTab = .variables
    @State private var diffs: [ExampleDiffService.Diff] = []
    @State private var scanCandidates: [MonorepoScanner.Candidate]?

    enum DetailTab { case variables, gitChanges }

    private var isLinked: Bool { RepositoryService.resolveBookmark(repo) != nil }
    private var targets: [Target] { (repo.targets ?? []).sorted { $0.relativePath < $1.relativePath } }
    private var selectedTarget: Target? {
        targets.first { $0.relativePath == selectedTargetPath } ?? targets.first
    }
    private var environmentNames: [String] {
        (repo.workspace?.environments ?? []).sorted { $0.sortOrder < $1.sortOrder }.map(\.name)
    }
    private var diffCount: Int { diffs.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .variables:
                if let target = selectedTarget {
                    VariablesView(target: target, environmentName: environmentName)
                        .id("\(target.persistentModelID)-\(environmentName)")
                } else {
                    Text("Target이 없습니다").foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                }
            case .gitChanges:
                GitChangesView(diffs: diffs, environmentNames: environmentNames,
                               onChanged: refreshDiffs)
            }
        }
        .navigationTitle(repo.name)
        .navigationSubtitle("\(selectedTargetPath) · \(environmentName)")
        .toolbar {
            Button("Scan", systemImage: "arrow.trianglehead.2.clockwise") { scanMonorepo(auto: false) }
                .help("Monorepo Target 탐색 및 example 변경 감지")
            Button("Generate", systemImage: "square.and.arrow.down") { prepareGenerate() }
                .help("\(environmentName) 기준으로 .env 파일 생성")
        }
        .task(id: repo.uuid) {
            refreshDiffs()
            autoScanIfFirstVisit()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDiffs()   // git pull 후 앱 전환 시 감지 (§3.6)
        }
        .sheet(isPresented: .constant(scanCandidates != nil), onDismiss: { scanCandidates = nil }) {
            if let candidates = scanCandidates {
                TargetScanSheet(repo: repo, candidates: candidates) {
                    scanCandidates = nil
                    refreshDiffs()
                }
            }
        }
        .sheet(isPresented: .constant(generatePlans != nil), onDismiss: { generatePlans = nil }) {
            if let plans = generatePlans, let rootURL = generateRootURL {
                GenerateSheet(plans: plans, rootURL: rootURL, environmentName: environmentName)
            }
        }
        .alert("Generate 불가", isPresented: .constant(generateError != nil)) {
            Button("확인") { generateError = nil }
        } message: {
            Text(generateError ?? "")
        }
        .fileImporter(isPresented: $showRelinker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            try? RepositoryService.relink(repo: repo, folderURL: url, context: context)
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
                    Text(diffCount > 0 ? "Git Changes (\(diffCount))" : "Git Changes")
                        .tag(DetailTab.gitChanges)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                if tab == .variables && targets.count > 1 {
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
