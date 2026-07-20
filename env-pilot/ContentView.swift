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
    @State private var selection: Repository?
    @State private var showImporter = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            List(repositories, selection: $selection) { repo in
                Label(repo.name, systemImage: "folder")
                    .tag(repo)
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
                RepositoryDetailView(repo: repo, onDelete: { deleteRepo(repo) })
            } else {
                Text("Repository를 선택하세요")
                    .foregroundStyle(.secondary)
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
    let onDelete: () -> Void
    @Environment(\.modelContext) private var context
    @State private var showRelinker = false

    private var isLinked: Bool { RepositoryService.resolveBookmark(repo) != nil }

    var body: some View {
        Form {
            Section("정보") {
                LabeledContent("이름", value: repo.name)
                LabeledContent("경로", value: repo.localPathDisplay ?? "-")
                LabeledContent("Remote", value: repo.gitRemoteURL ?? "Git remote 없음")
                LabeledContent("Branch", value: repo.defaultBranch ?? "-")
            }

            if !isLinked {
                Section {
                    Label("이 Mac에서 폴더에 접근할 수 없습니다", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("폴더 다시 연결…") { showRelinker = true }
                }
            }

            Section("Targets") {
                ForEach(repo.targets ?? []) { target in
                    LabeledContent(target.relativePath) {
                        Text("\(target.examplePath) → \(target.outputPath)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Repository 삭제", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(repo.name)
        .fileImporter(isPresented: $showRelinker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            try? RepositoryService.relink(repo: repo, folderURL: url, context: context)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Workspace.self, HistoryEntry.self], inMemory: true)
}
