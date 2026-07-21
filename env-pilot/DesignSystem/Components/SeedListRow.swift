import SwiftUI

extension View {
    /// seed list-item 데스크톱 적용 — List 행 콘텐츠에 사용.
    /// 기준 타이포 t4·최소 높이 32로 행 높이/글자 크기를 탭 간 통일.
    /// (seed 원본 paddingY 12px → 데스크톱 밀도에 맞춰 8px)
    func seedListRow() -> some View {
        font(SeedFont.t4())
            .frame(minHeight: SeedSpacing.x8)
            .padding(.vertical, SeedSpacing.x2)
            .listRowSeparatorTint(SeedColor.strokeNeutralMuted)
    }
}
