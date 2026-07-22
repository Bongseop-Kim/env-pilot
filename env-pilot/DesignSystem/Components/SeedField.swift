import SwiftUI

/// seed field 포팅 — 라벨 + 인풋 + 설명 조합. SeedTextField와 함께 폼을 구성.
struct SeedField<Content: View>: View {
    let label: String
    var description: String?
    @ViewBuilder let content: Content

    init(_ label: String, description: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.label = label
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SeedSpacing.x2) {
            Text(label)
                .font(SeedTypography.section)
                .foregroundStyle(SeedColor.fgNeutralMuted)
                .padding(.horizontal, SeedSpacing.x0_5)
            content
            if let description {
                Text(description)
                    .font(SeedTypography.bodyLarge)
                    .foregroundStyle(SeedColor.fgNeutralSubtle)
                    .padding(.horizontal, SeedSpacing.x0_5)
            }
        }
    }
}
