import SwiftUI
import SwiftData
import AppKit

/// 메뉴바 빠른 기능 — Repository Health와 변경 확인.
struct MenuBarView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Repository.createdAt) private var repositories: [Repository]
    @State private var healthByRepo: [String: String] = [:]   // 메뉴 렌더마다 동기 파일 스캔 방지 캐시

    var body: some View {
        // Repository별 Health
        ForEach(repositories) { repo in
            Text("\(healthByRepo[repo.uuid] ?? "…") \(repo.name)")
        }
        .onAppear { refreshHealth() }

        Divider()

        Button("변경 확인") { scanAll() }

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
                let items = HealthService.check(repo: repo, rootURL: rootURL)
                healthByRepo[repo.uuid] = HealthService.overall(items).symbol
                await Task.yield()   // repo가 많아도 메뉴 UI가 멈추지 않게
            }
        }
    }

    private func scanAll() {
        for repo in repositories {
            guard let rootURL = RepositoryService.resolveBookmark(repo) else { continue }
            _ = LocalSyncService.reconcile(repo: repo, rootURL: rootURL, context: context)
            _ = ExampleDiffService.scan(repo: repo, rootURL: rootURL, context: context)
        }
    }
}
