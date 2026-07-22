import SwiftUI
import SwiftData

/// 변경 이력 (PRD §3.10) — 날짜별 그룹, Repository/파일 필터, 최근 1000건 보존.
struct HistoryView: View {
    @Query(sort: \HistoryEntry.timestamp, order: .reverse) private var entries: [HistoryEntry]
    @Environment(\.modelContext) private var context
    @State private var repositoryFilter = "전체"
    @State private var fileFilter = "전체"
    @State private var showDeleteAllConfirm = false

    private var filtered: [HistoryEntry] {
        entries.filter {
            (repositoryFilter == "전체" || $0.repositoryName == repositoryFilter)
                && (fileFilter == "전체" || $0.targetPath == fileFilter)
        }
    }

    private var days: [(day: Date, batches: [[HistoryEntry]])] {
        Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.timestamp) }
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, batches: batchGroups($0.value)) }
    }

    /// batchId가 같은 항목을 하나의 행동으로 묶는다. 단건(batchId nil)은 1개짜리 그룹.
    private func batchGroups(_ entries: [HistoryEntry]) -> [[HistoryEntry]] {
        var indexByBatch: [UUID: Int] = [:]
        var groups: [[HistoryEntry]] = []
        for entry in entries {
            if let id = entry.batchId, let index = indexByBatch[id] {
                groups[index].append(entry)
            } else {
                if let id = entry.batchId { indexByBatch[id] = groups.count }
                groups.append([entry])
            }
        }
        return groups
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView("이력 없음", systemImage: "clock",
                                       description: Text("변수나 Account를 변경하면 이력이 기록됩니다"))
            } else {
                List {
                    ForEach(days, id: \.day) { group in
                        Section(dayLabel(group.day)) {
                            ForEach(group.batches, id: \.first!.id) { batch in
                                if batch.count == 1 {
                                    row(batch[0])
                                        .contextMenu {
                                            Button("삭제", role: .destructive) { delete(batch[0]) }
                                        }
                                } else {
                                    DisclosureGroup {
                                        ForEach(batch) { entry in
                                            row(entry)
                                                .contextMenu {
                                                    Button("삭제", role: .destructive) { delete(entry) }
                                                }
                                        }
                                    } label: {
                                        batchRow(batch)
                                    }
                                    .contextMenu {
                                        Button("삭제", role: .destructive) {
                                            batch.forEach(delete)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            Picker("Repository", selection: $repositoryFilter) {
                Text("전체 Repository").tag("전체")
                ForEach(Set(entries.map(\.repositoryName)).sorted(), id: \.self) { Text($0).tag($0) }
            }
            .help("Repository별 이력 필터")
            Picker("파일", selection: $fileFilter) {
                Text("전체 파일").tag("전체")
                ForEach(Set(entries.map(\.targetPath)).filter { !$0.isEmpty }.sorted(), id: \.self) {
                    Text($0).tag($0)
                }
            }
            .help("env 파일별 이력 필터")
            Button("이력 삭제", systemImage: "trash") { showDeleteAllConfirm = true }
                .help(repositoryFilter == "전체" && fileFilter == "전체"
                      ? "전체 이력 삭제" : "필터에 표시된 이력 삭제")
                .disabled(filtered.isEmpty)
        }
        .confirmationDialog("표시된 이력 \(filtered.count)건을 삭제할까요?",
                            isPresented: $showDeleteAllConfirm) {
            Button("삭제", role: .destructive) { deleteFiltered() }
        } message: {
            Text("삭제한 이력은 복구할 수 없습니다.")
        }
        .task { trim() }
    }

    private func delete(_ entry: HistoryEntry) {
        context.delete(entry)
        try? context.save()
    }

    /// 현재 필터에 표시된 이력만 삭제 — 필터가 "전체"면 전체 삭제와 동일.
    private func deleteFiltered() {
        for entry in filtered { context.delete(entry) }
        try? context.save()
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack {
            Image(systemName: icon(entry.action).0)
                .foregroundStyle(icon(entry.action).1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.key).fontDesign(.monospaced).fontWeight(.medium)
                    Text(actionLabel(entry.action)).foregroundStyle(SeedColor.fgNeutralMuted)
                }
                Text(subtitle(entry))
                    .font(SeedTypography.body)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
            }
            Spacer()
            Text(entry.timestamp, style: .time)
                .font(SeedTypography.body)
                .foregroundStyle(SeedColor.fgNeutralMuted)
        }
        .seedListRow()
    }

    /// 여러 키가 한 행동(import/sync)으로 바뀐 묶음의 요약 행.
    private func batchRow(_ batch: [HistoryEntry]) -> some View {
        HStack {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(SeedColor.fgBrand)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sourceLabel(batch[0].source)).fontWeight(.medium)
                    Text("\(batch.count)개 변경").foregroundStyle(SeedColor.fgNeutralMuted)
                }
                Text(subtitle(batch[0], includeSource: false))
                    .font(SeedTypography.body)
                    .foregroundStyle(SeedColor.fgNeutralMuted)
            }
            Spacer()
            Text(batch[0].timestamp, style: .time)
                .font(SeedTypography.body)
                .foregroundStyle(SeedColor.fgNeutralMuted)
        }
        .seedListRow()
    }

    /// "repo · 파일경로 · 출처" — 빈 항목은 생략 (Accounts 이력은 파일 경로가 없다).
    private func subtitle(_ entry: HistoryEntry, includeSource: Bool = true) -> String {
        [entry.repositoryName,
         entry.targetPath.isEmpty ? nil : entry.targetPath,
         !includeSource || entry.source == "manual" ? nil : sourceLabel(entry.source)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "fileImport": "파일 가져오기"
        case "bundleImport": "번들 가져오기"
        case "exampleSync": "example 동기화"
        case "localSync": "로컬 동기화"
        case "credential": "Account"
        default: source
        }
    }

    private func icon(_ action: String) -> (String, Color) {
        switch action {
        case "created": ("plus.circle.fill", SeedColor.fgPositive)
        case "deleted": ("minus.circle.fill", SeedColor.fgCritical)
        default: ("pencil.circle.fill", SeedColor.fgBrand)
        }
    }

    private func actionLabel(_ action: String) -> String {
        switch action {
        case "created": "추가"
        case "deleted": "삭제"
        case "renamed": "이름 변경"
        default: "변경"
        }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    /// 최근 1000건 초과분 삭제 (§3.10).
    private func trim() {
        guard entries.count > 1000 else { return }
        for entry in entries.dropFirst(1000) { context.delete(entry) }
        try? context.save()
    }
}
