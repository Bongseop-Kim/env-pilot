import SwiftUI

/// seed callout 포팅 — 톤 배경 + 아이콘의 인라인 안내 박스.
struct SeedCallout<Content: View>: View {
    var tone: SeedTone = .neutral
    var systemImage: String?
    @ViewBuilder let content: Content

    init(tone: SeedTone = .neutral, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SeedSpacing.x2) {
            Image(systemName: systemImage ?? defaultIcon)
                .foregroundStyle(tone.fg)
            content
                .font(SeedTypography.bodyLarge)
        }
        .padding(SeedSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.bgWeak, in: .rect(cornerRadius: SeedRadius.r3))
    }

    private var defaultIcon: String {
        switch tone {
        case .neutral, .informative: "info.circle.fill"
        case .brand: "sparkles"
        case .positive: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

extension SeedCallout where Content == Text {
    init(_ text: String, tone: SeedTone = .neutral, systemImage: String? = nil) {
        self.init(tone: tone, systemImage: systemImage) { Text(text) }
    }
}
