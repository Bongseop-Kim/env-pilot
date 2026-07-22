import SwiftUI

extension HealthStatus {
    var seedTone: SeedTone {
        switch self {
        case .healthy: .positive
        case .warning: .warning
        case .critical: .critical
        }
    }

    var color: Color { seedTone.fg }
}

/// Health 탭 (PRD §3.8) — 실제 env 파일이 example 키를 충족하는지 판정.
/// secret 노출 방지(Git Safety·히스토리·hook·AI)는 SecurityView로 분리.
struct HealthView: View {
    let items: [HealthService.Item]
    let onSelectMissingKey: (_ filePath: String, _ key: String) -> Void

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("판정 대상 없음", systemImage: "questionmark.circle",
                                   description: Text(".env.example과 함께 확인할 실제 env 파일이 없습니다"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // 상단 정렬 VStack 안에서 중앙 배치
        } else {
            List {
                if items.allSatisfy({ $0.status == .healthy }) {
                    Label("All Healthy — 모든 .env 파일이 example 키를 충족합니다",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(SeedColor.fgPositive)
                        .seedListRow()
                } else {
                    healthSections
                }
            }
        }
    }

    @ViewBuilder private var healthSections: some View {
        ForEach(items) { item in
            HStack(alignment: .top) {
                Image(systemName: item.status.iconName)
                    .foregroundStyle(item.status.color)
                Text(item.filePath)
                    .fontDesign(.monospaced)
                    .frame(width: 180, alignment: .leading)
                keyChips(item)
                Spacer()
            }
            .seedListRow()
        }
    }

    @ViewBuilder private func keyChips(_ item: HealthService.Item) -> some View {
        if item.status == .healthy {
            Text("Healthy").foregroundStyle(SeedColor.fgNeutralMuted).font(SeedTypography.body)
        } else {
            // 누락 키 클릭 → 해당 Variable 입력으로 이동 (§3.8 수용 기준)
            WrappingHStack {
                ForEach(item.missingKeys, id: \.self) { key in
                    Button("\(key) 누락") {
                        onSelectMissingKey(item.filePath, key)
                    }
                    .buttonStyle(.seedChip(.critical))
                }
                ForEach(item.emptyValueKeys, id: \.self) { key in
                    Button("\(key) 빈 값") {
                        onSelectMissingKey(item.filePath, key)
                    }
                    .buttonStyle(.seedChip(.warning))
                }
            }
        }
    }
}
