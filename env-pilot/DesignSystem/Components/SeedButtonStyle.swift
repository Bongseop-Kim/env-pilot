import SwiftUI

/// seed action-button 포팅 — 콘텐츠 영역 버튼용. 창 크롬(툴바 등)은 네이티브 유지.
/// 사용: `.buttonStyle(.seed(.neutralWeak, size: .small))`
struct SeedButtonStyle: ButtonStyle {
    enum Variant { case brandSolid, neutralWeak, criticalSolid, ghost }

    enum Size {
        case xsmall  // h32, padX 14, padY 6, 캡슐, t3 — 리스트 행 인라인 액션용
        case small   // h36, padX 14, padY 8
        case medium  // h40, padX 16, padY 10

        var minHeight: CGFloat {
            switch self {
            case .xsmall: SeedSpacing.x8
            case .small: SeedSpacing.x9
            case .medium: SeedSpacing.x10
            }
        }
        var paddingX: CGFloat { self == .medium ? SeedSpacing.x4 : SeedSpacing.x3_5 }
        var paddingY: CGFloat {
            switch self {
            case .xsmall: SeedSpacing.x1_5
            case .small: SeedSpacing.x2
            case .medium: SeedSpacing.x2_5
            }
        }
        var cornerRadius: CGFloat { self == .xsmall ? SeedRadius.full : SeedRadius.r2 }
        var font: Font { self == .xsmall ? SeedFont.t3(.bold) : SeedFont.t4(.bold) }
        var pressedScale: CGFloat { self == .xsmall ? SeedScale.s95 : SeedScale.s97 }
    }

    var variant: Variant = .brandSolid
    var size: Size = .medium
    var iconOnly = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(size.font)
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? size.paddingY : size.paddingX)
            .padding(.vertical, size.paddingY)
            .frame(minWidth: iconOnly ? size.minHeight : nil, minHeight: size.minHeight)
            .background(background(pressed: pressed), in: .rect(cornerRadius: size.cornerRadius))
            .contentShape(.rect(cornerRadius: size.cornerRadius))
            .scaleEffect(pressed && !reduceMotion ? size.pressedScale : 1)
            .animation(SeedEasing.pressedScale(), value: pressed)
    }

    private var foreground: Color {
        guard isEnabled else { return SeedColor.fgDisabled }
        switch variant {
        case .brandSolid, .criticalSolid: return SeedColor.Palette.staticWhite
        case .neutralWeak, .ghost: return SeedColor.fgNeutral
        }
    }

    private func background(pressed: Bool) -> Color {
        guard isEnabled else { return variant == .ghost ? .clear : SeedColor.bgDisabled }
        switch variant {
        case .brandSolid: return pressed ? SeedColor.bgBrandSolidPressed : SeedColor.bgBrandSolid
        case .criticalSolid: return pressed ? SeedColor.bgCriticalSolidPressed : SeedColor.bgCriticalSolid
        case .neutralWeak: return pressed ? SeedColor.bgNeutralWeakPressed : SeedColor.bgNeutralWeak
        case .ghost: return pressed ? SeedColor.bgTransparentPressed : .clear
        }
    }
}

extension ButtonStyle where Self == SeedButtonStyle {
    static func seed(_ variant: SeedButtonStyle.Variant = .brandSolid,
                     size: SeedButtonStyle.Size = .medium) -> SeedButtonStyle {
        SeedButtonStyle(variant: variant, size: size)
    }

    /// 아이콘 전용 버튼 (복사·열기 등 행 내부 액션)
    static func seedIcon(_ variant: SeedButtonStyle.Variant = .ghost,
                         size: SeedButtonStyle.Size = .xsmall) -> SeedButtonStyle {
        SeedButtonStyle(variant: variant, size: size, iconOnly: true)
    }
}
