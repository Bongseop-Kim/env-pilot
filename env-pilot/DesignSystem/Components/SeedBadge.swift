import SwiftUI

/// seed badge 포팅 — medium 사이즈 고정 (h20, padX 6, padY 2, r1, t1).
struct SeedBadge: View {
    enum Variant { case weak, solid, outline }

    let text: String
    var tone: SeedTone = .neutral
    var variant: Variant = .weak

    init(_ text: String, tone: SeedTone = .neutral, variant: Variant = .weak) {
        self.text = text
        self.tone = tone
        self.variant = variant
    }

    var body: some View {
        Text(text)
            .font(SeedFont.t1(variant == .solid ? .bold : .medium))
            .foregroundStyle(labelColor)
            .padding(.horizontal, SeedSpacing.x1_5)
            .padding(.vertical, SeedSpacing.x0_5)
            .frame(minHeight: SeedSpacing.x5)
            .background(backgroundColor, in: .rect(cornerRadius: SeedRadius.r1))
            .overlay {
                if variant == .outline {
                    RoundedRectangle(cornerRadius: SeedRadius.r1)
                        .strokeBorder(tone.strokeWeak, lineWidth: 1)
                }
            }
    }

    private var labelColor: Color {
        switch variant {
        case .solid:
            // 밝은 노랑 solid 배경 위에서는 정적 검정이 양 테마 모두 대비 확보
            tone == .warning ? SeedColor.Palette.staticBlack : SeedColor.fgNeutralInverted
        case .weak, .outline:
            tone == .neutral ? SeedColor.fgNeutralMuted : tone.fg
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .solid: tone.bgSolid
        case .weak: tone.bgWeak
        case .outline: .clear
        }
    }
}
