import SwiftUI

/// seed tabs(hug/small) 포팅 — 밑줄 인디케이터가 슬라이드하는 상단 탭.
/// 하단 1px 스트로크는 호출측 레이아웃(헤더 Divider 등)에 맡긴다.
struct SeedTabs<Value: Hashable>: View {
    let items: [(Value, String)]
    @Binding var selection: Value

    @Namespace private var indicatorNS

    init(selection: Binding<Value>, items: [(Value, String)]) {
        self._selection = selection
        self.items = items
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                let (value, label) = item
                let isSelected = value == selection
                Button {
                    withAnimation(SeedEasing.easing(SeedDuration.d4)) { selection = value }
                } label: {
                    Text(label)
                        .font(SeedTypography.sectionBold)
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
