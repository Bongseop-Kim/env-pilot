import SwiftUI

/// seed action-chip(small) 포팅 — 캡슐 칩 버튼.
/// seed 원본은 neutral 전용이지만 상태 칩(누락/빈 값)용으로 톤을 확장.
struct SeedChipStyle: ButtonStyle {
    var tone: SeedTone = .neutral

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 13pt 리스트 행 안에 인라인 배치 — 본문보다 커지지 않게 라벨 크기로 고정
            .font(SeedFont.t2(.medium))
            .foregroundStyle(isEnabled ? (tone == .neutral ? SeedColor.fgNeutral : tone.fg) : SeedColor.fgDisabled)
            .padding(.horizontal, SeedSpacing.x2)
            .padding(.vertical, SeedSpacing.x1)
            .frame(minHeight: SeedSpacing.x6)
            .background(background(pressed: configuration.isPressed), in: .capsule)
            .contentShape(.capsule)
            .animation(SeedEasing.easing(), value: configuration.isPressed)
    }

    private func background(pressed: Bool) -> Color {
        guard isEnabled else { return SeedColor.bgDisabled }
        switch tone {
        case .neutral: return pressed ? SeedColor.bgNeutralWeakPressed : SeedColor.bgNeutralWeak
        case .brand: return pressed ? SeedColor.bgBrandWeakPressed : SeedColor.bgBrandWeak
        case .positive: return pressed ? SeedColor.bgPositiveWeakPressed : SeedColor.bgPositiveWeak
        case .warning: return pressed ? SeedColor.bgWarningWeakPressed : SeedColor.bgWarningWeak
        case .critical: return pressed ? SeedColor.bgCriticalWeakPressed : SeedColor.bgCriticalWeak
        case .informative: return pressed ? SeedColor.bgInformativeWeakPressed : SeedColor.bgInformativeWeak
        }
    }
}

extension ButtonStyle where Self == SeedChipStyle {
    static func seedChip(_ tone: SeedTone = .neutral) -> SeedChipStyle {
        SeedChipStyle(tone: tone)
    }
}
