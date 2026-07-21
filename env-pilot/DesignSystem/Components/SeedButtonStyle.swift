import SwiftUI

/// seed action-button 포팅 — 콘텐츠 영역 버튼용. 창 크롬(툴바 등)은 네이티브 유지.
/// 사용: `.buttonStyle(.seed(.neutralWeak, size: .small))`
struct SeedButtonStyle: ButtonStyle {
    enum Variant { case brandSolid, neutralWeak, criticalSolid, ghost }

    enum Size {
        case small   // h36, padX 14, padY 8
        case medium  // h40, padX 16, padY 10

        var minHeight: CGFloat { self == .small ? SeedSpacing.x9 : SeedSpacing.x10 }
        var paddingX: CGFloat { self == .small ? SeedSpacing.x3_5 : SeedSpacing.x4 }
        var paddingY: CGFloat { self == .small ? SeedSpacing.x2 : SeedSpacing.x2_5 }
    }

    var variant: Variant = .brandSolid
    var size: Size = .medium

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(SeedFont.t4(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, size.paddingX)
            .padding(.vertical, size.paddingY)
            .frame(minHeight: size.minHeight)
            .background(background(pressed: pressed), in: .rect(cornerRadius: SeedRadius.r2))
            .contentShape(.rect(cornerRadius: SeedRadius.r2))
            .scaleEffect(pressed && !reduceMotion ? SeedScale.s97 : 1)
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
}
