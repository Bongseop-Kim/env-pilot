import SwiftUI

/// seed segmented-control 포팅 — 캡슐 트랙 위를 흰 필 인디케이터가 슬라이드.
struct SeedSegmentedControl<Value: Hashable>: View {
    let items: [(Value, String)]
    @Binding var selection: Value

    @Namespace private var pillNS

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
                        .font(SeedFont.t3(.bold))
                        .foregroundStyle(isSelected ? SeedColor.fgNeutral : SeedColor.fgNeutralSubtle)
                        .padding(.horizontal, SeedSpacing.x4)
                        .frame(minHeight: 28)   // ponytail: seed 34px → 데스크톱 행 밀도에 맞춰 축소
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(SeedColor.Palette.gray00)
                            .stroke(SeedColor.strokeNeutralMuted, lineWidth: 1)
                            .matchedGeometryEffect(id: "seed-segment-pill", in: pillNS)
                    }
                }
            }
        }
        .padding(SeedSpacing.x1)
        .background(SeedColor.bgNeutralWeakAlpha, in: .capsule)
    }
}
