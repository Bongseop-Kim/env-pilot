//
//  env_pilotApp.swift
//  env-pilot
//
//  Created by duegosystem on 7/20/26.
//

import SwiftUI
import SwiftData

@main
struct env_pilotApp: App {
    let container: ModelContainer

    init() {
        // ponytail: 로컬 전용 컨테이너 — Phase 4에서 cloudKitDatabase: .automatic으로 전환
        // HistoryEntry는 관계 그래프 밖이라 명시 필요
        container = try! ModelContainer(for: Workspace.self, HistoryEntry.self)
        Self.bootstrap(container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
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
}
