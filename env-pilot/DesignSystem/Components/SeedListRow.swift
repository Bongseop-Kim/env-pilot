import SwiftUI

extension View {
    /// seed list-item 데스크톱 적용 — List 행 콘텐츠에 사용.
    /// (seed 원본 paddingY 12px → 데스크톱 밀도에 맞춰 8px)
    func seedListRow() -> some View {
        padding(.vertical, SeedSpacing.x2)
            .listRowSeparatorTint(SeedColor.strokeNeutralMuted)
    }
}
