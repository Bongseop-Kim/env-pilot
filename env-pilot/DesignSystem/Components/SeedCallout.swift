import SwiftUI

/// seed callout 포팅 — 톤 배경 + 아이콘의 인라인 안내 박스.
struct SeedCallout: View {
    let text: String
    var tone: SeedTone = .neutral

    init(_ text: String, tone: SeedTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SeedSpacing.x2) {
            Image(systemName: icon)
                .foregroundStyle(tone.fg)
            Text(text)
                .font(SeedTypography.bodyLarge)
        }
        .padding(SeedSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.bgWeak, in: .rect(cornerRadius: SeedRadius.r3))
    }

    private var icon: String {
        switch tone {
        case .neutral: "info.circle.fill"
        case .positive: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}
