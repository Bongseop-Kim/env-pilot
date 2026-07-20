import SwiftUI
import SwiftData

/// 변경 이력 (PRD §3.10) — 날짜별 그룹, Repository/Environment 필터, 최근 1000건 보존.
struct HistoryView: View {
    @Query(sort: \HistoryEntry.timestamp, order: .reverse) private var entries: [HistoryEntry]
    @Environment(\.modelContext) private var context
    @State private var repositoryFilter = "전체"
    @State private var environmentFilter = "전체"

    private var filtered: [HistoryEntry] {
        entries.filter {
            (repositoryFilter == "전체" || $0.repositoryName == repositoryFilter)
                && (environmentFilter == "전체" || $0.environmentName == environmentFilter)
        }
    }

    private var days: [(day: Date, entries: [HistoryEntry])] {
        Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.timestamp) }
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, entries: $0.value) }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView("이력 없음", systemImage: "clock",
                                       description: Text("변수를 변경하면 이력이 기록됩니다"))
            } else {
                List {
                    ForEach(days, id: \.day) { group in
                        Section(dayLabel(group.day)) {
                            ForEach(group.entries) { entry in
                                row(entry)
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
            Picker("Environment", selection: $environmentFilter) {
                Text("전체 Environment").tag("전체")
                ForEach(Set(entries.map(\.environmentName)).sorted(), id: \.self) { Text($0).tag($0) }
            }
        }
        .task { trim() }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack {
            Image(systemName: icon(entry.action).0)
                .foregroundStyle(icon(entry.action).1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.key).fontDesign(.monospaced).fontWeight(.medium)
                    Text(actionLabel(entry.action)).foregroundStyle(.secondary)
                }
                Text("\(entry.repositoryName) · \(entry.targetPath) · \(entry.environmentName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func icon(_ action: String) -> (String, Color) {
        switch action {
        case "created": ("plus.circle.fill", .green)
        case "deleted": ("minus.circle.fill", .red)
        default: ("pencil.circle.fill", .orange)
        }
    }

    private func actionLabel(_ action: String) -> String {
        switch action {
        case "created": "추가"
        case "deleted": "삭제"
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
