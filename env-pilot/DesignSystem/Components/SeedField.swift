import SwiftUI

/// seed field 포팅 — 라벨 + 인풋 + 설명/에러 조합. SeedTextField와 함께 폼을 구성.
struct SeedField<Content: View>: View {
    let label: String
    var description: String?
    var errorMessage: String?
    @ViewBuilder let content: Content

    init(_ label: String, description: String? = nil, errorMessage: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.label = label
        self.description = description
        self.errorMessage = errorMessage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SeedSpacing.x2) {
            Text(label)
                .font(SeedTypography.section)
                .foregroundStyle(SeedColor.fgNeutralMuted)
                .padding(.horizontal, SeedSpacing.x0_5)
            content
            if let errorMessage {
                footer(errorMessage, icon: "exclamationmark.circle.fill", color: SeedColor.fgCritical)
            } else if let description {
                footer(description, icon: nil, color: SeedColor.fgNeutralSubtle)
            }
        }
    }

    private func footer(_ text: String, icon: String?, color: Color) -> some View {
        HStack(spacing: SeedSpacing.x1_5) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(SeedTypography.bodyLarge)
        .foregroundStyle(color)
        .padding(.horizontal, SeedSpacing.x0_5)
    }
}
