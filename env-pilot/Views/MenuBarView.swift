import SwiftUI
import SwiftData
import AppKit

/// 메뉴바 빠른 기능 (PRD §4.4) — Environment 전환, Health 요약, Generate, Scan.
struct MenuBarView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Query private var workspaces: [Workspace]
    @Query(sort: \Repository.createdAt) private var repositories: [Repository]
    @AppStorage("selectedEnvironment") private var selectedEnvironment = "Local"
    @State private var healthByRepo: [String: String] = [:]   // 메뉴 렌더마다 동기 파일 스캔 방지 캐시

    private var environmentNames: [String] {
        (workspaces.first?.environments ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.name)
    }

    var body: some View {
        Picker("Environment", selection: $selectedEnvironment) {
            ForEach(environmentNames, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.inline)
        .onAppear { refreshHealth() }   // 메뉴가 열린 뒤 갱신 — 열기 자체는 즉시

        Divider()

        // Repository별 Health 요약 (표시 전용)
        ForEach(repositories) { repo in
            Text("\(healthByRepo[repo.uuid] ?? "…") \(repo.name)")
        }

        Divider()

        Menu("Generate — \(selectedEnvironment)") {
            ForEach(repositories) { repo in
                Button(repo.name) { generate(repo) }
                    .disabled(RepositoryService.resolveBookmark(repo) == nil)
            }
        }
        Button("Scan Now") { scanAll() }

        Divider()

        Button("Env IDE 열기") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("종료") { NSApp.terminate(nil) }
    }

    private func refreshHealth() {
        Task {
            for repo in repositories {
                guard let rootURL = RepositoryService.resolveBookmark(repo) else {
                    healthByRepo[repo.uuid] = "⚠️"
                    continue
                }
                let items = HealthService.check(repo: repo, rootURL: rootURL,
                                                environmentNames: environmentNames)
                healthByRepo[repo.uuid] = HealthService.overall(items).symbol
                await Task.yield()   // repo가 많아도 메뉴 UI가 멈추지 않게
            }
        }
    }

    /// 메뉴바 Generate는 확인 없이 즉시 실행 — 앱 데이터가 .env의 소스라는 전제 (§16).
    private func generate(_ repo: Repository) {
        guard let rootURL = RepositoryService.resolveBookmark(repo) else { return }
        let plans = GenerateService.makePlans(repo: repo, rootURL: rootURL, environmentName: selectedEnvironment)
        let errors = GenerateService.execute(plans, rootURL: rootURL)
        if errors.isEmpty {
            GenerateService.recordOutputHashes(plans: plans, repo: repo)  // §3.18 drift 기준점
            try? context.save()
        }
    }

    private func scanAll() {
        for repo in repositories {
            guard let rootURL = RepositoryService.resolveBookmark(repo) else { continue }
            _ = ExampleDiffService.scan(repo: repo, rootURL: rootURL, context: context)
        }
    }
}
