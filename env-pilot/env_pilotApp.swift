//
//  env_pilotApp.swift
//  env-pilot
//
//  Created by duegosystem on 7/20/26.
//

import SwiftUI
import SwiftData
import Sparkle

@main
struct env_pilotApp: App {
    let container: ModelContainer
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // §3.13: iCloud 동기화 — 토글(Settings)은 재시작 후 적용. 컨테이너는 시작 시 1회 구성.
        // HistoryEntry는 관계 그래프 밖이라 명시 필요.
        let schema = Schema([Workspace.self, HistoryEntry.self])
        let cloudContainer = UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")
            ? try? ModelContainer(for: schema,
                                  configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .automatic))
            : nil
        // entitlement/iCloud 계정 미설정으로 CloudKit 컨테이너 생성이 실패하면 로컬로 폴백
        container = cloudContainer ?? (try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none)))
        SecretStore.migrateLegacyItems()  // §3.13: 로그인 키체인 → iCloud Keychain 1회 이전
        Self.bootstrap(container.mainContext)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .windowToolbarStyle(.unified(showsTitle: false))  // 툴바에 앱 이름 표시 안 함
        .modelContainer(container)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        // 메뉴바 빠른 기능 (PRD §4.4)
        MenuBarExtra("Env IDE", systemImage: "key.fill") {
            MenuBarView()
                .modelContainer(container)
        }

        Settings {
            SettingsView()
                .modelContainer(container)
        }
    }

    /// 첫 실행 시 기본 Workspace + Environment 4종 생성.
    static func bootstrap(_ context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<Workspace>())) ?? 0
        guard existing == 0 else { return }

        let workspace = Workspace()
        context.insert(workspace)
        for (i, name) in Workspace.defaultEnvironmentNames.enumerated() {
            let env = EnvEnvironment(name: name, sortOrder: i)
            env.workspace = workspace
            context.insert(env)
        }
        try? context.save()
    }

    /// §3.13: 새 Mac의 bootstrap과 CloudKit 동기화가 만나면 Workspace가 중복된다.
    /// 가장 오래된 것 하나로 병합하고 Environment도 이름 기준으로 중복 제거. 멱등 — 앱 활성화 시마다 호출.
    static func dedupeAfterSync(_ context: ModelContext) {
        guard let workspaces = try? context.fetch(FetchDescriptor<Workspace>(
            sortBy: [SortDescriptor(\.createdAt)])), workspaces.count > 1 else { return }

        let keeper = workspaces[0]
        for duplicate in workspaces.dropFirst() {
            for repo in duplicate.repositories ?? [] { repo.workspace = keeper }
            for env in duplicate.environments ?? [] { env.workspace = keeper }
            context.delete(duplicate)
        }
        var seen = Set<String>()
        for env in (keeper.environments ?? []).sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if seen.insert(env.name).inserted == false { context.delete(env) }
        }
        try? context.save()
    }
}
