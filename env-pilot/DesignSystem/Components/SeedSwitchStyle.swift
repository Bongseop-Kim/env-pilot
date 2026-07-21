import SwiftUI

/// seed switch(size 24) 포팅 — 트랙 38×24, 썸 20, 선택 시 brand-solid.
/// 사용: `.toggleStyle(.seed)`
struct SeedSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(SeedEasing.easing(SeedDuration.d3)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: SeedSpacing.x2) {
                configuration.label
                    .font(SeedTypography.section)
                    .foregroundStyle(SeedColor.fgNeutral)
                    .opacity(isEnabled ? 1 : 0.58)
                Spacer(minLength: 0)
                track(isOn: configuration.isOn)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func track(isOn: Bool) -> some View {
        Capsule()
            .fill(isOn ? SeedColor.bgBrandSolid : SeedColor.Palette.gray600)
            .frame(width: 38, height: 24)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(SeedColor.Palette.staticWhite)
                    .frame(width: 20, height: 20)
                    .scaleEffect(isOn ? 1 : 0.8)   // seed switchmark: enabled 0.8 → selected 1
                    .padding(2)
            }
            .opacity(isEnabled ? 1 : 0.38)
    }
}

extension ToggleStyle where Self == SeedSwitchStyle {
    static var seed: SeedSwitchStyle { SeedSwitchStyle() }
}
