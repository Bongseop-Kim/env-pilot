import SwiftUI

/// seed select-box(horizontal) 포팅 — 선택 가능한 옵션 카드.
struct SeedSelectBox: View {
    let label: String
    var description: String?
    let isSelected: Bool
    let action: () -> Void

    init(_ label: String, description: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.description = description
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: SeedSpacing.x3) {
                VStack(alignment: .leading, spacing: SeedSpacing.x0_5) {
                    Text(label)
                        .font(SeedFont.t4(.medium))
                        .foregroundStyle(SeedColor.fgNeutral)
                    if let description {
                        Text(description)
                            .font(SeedFont.t3())
                            .foregroundStyle(SeedColor.fgNeutralMuted)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(SeedFont.t3(.bold))
                        .foregroundStyle(SeedColor.fgNeutral)
                }
            }
            .padding(.leading, SeedSpacing.x5)
            .padding(.trailing, SeedSpacing.x4)
            .padding(.vertical, SeedSpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: SeedRadius.r3))
        }
        .buttonStyle(SelectBoxPressStyle(isSelected: isSelected))
    }
}

private struct SelectBoxPressStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? SeedColor.bgTransparentPressed : SeedColor.bgTransparent,
                in: .rect(cornerRadius: SeedRadius.r3)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SeedRadius.r3)
                    .strokeBorder(isSelected ? SeedColor.strokeNeutralContrast : SeedColor.strokeNeutralMuted,
                                  lineWidth: isSelected ? 2 : 1)
            }
            .animation(SeedEasing.easing(), value: isSelected)
    }
}
