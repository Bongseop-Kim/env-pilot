import SwiftUI

/// seed tabs(hug/small) 포팅 — 밑줄 인디케이터가 슬라이드하는 상단 탭. 아이콘+텍스트 상시 표시.
/// 하단 1px 스트로크는 호출측 레이아웃(헤더 Divider 등)에 맡긴다.
struct SeedTabs<Value: Hashable>: View {
    let items: [(Value, String, String?)]
    let badges: [Value: Color]

    @Binding var selection: Value

    @Namespace private var indicatorNS

    init(selection: Binding<Value>, items: [(Value, String, String?)],
         badges: [Value: Color] = [:]) {
        self._selection = selection
        self.items = items
        self.badges = badges
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                let (value, label, icon) = item
                let isSelected = value == selection
                Button {
                    withAnimation(SeedEasing.easing(SeedDuration.d4)) { selection = value }
                } label: {
                    HStack(spacing: SeedSpacing.x1_5) {
                        if let icon {
                            Image(systemName: icon)
                                .font(SeedTypography.body)
                        }
                        Text(label)
                            .font(SeedTypography.sectionBold)
                        if let badgeColor = badges[value] {
                            Circle()
                                .fill(badgeColor)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(isSelected ? SeedColor.fgNeutral : SeedColor.fgNeutralSubtle)
                    .padding(.horizontal, SeedSpacing.x2_5)
                    .padding(.vertical, SeedSpacing.x2_5)
                    .frame(minHeight: 40)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(SeedColor.fgNeutral)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "seed-tab-indicator", in: indicatorNS)
                    }
                }
            }
        }
    }
}
