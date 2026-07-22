import SwiftUI

/// 상태 라벨 — 아이콘+텍스트에 seed 톤 컬러 적용. 산재한 `.foregroundStyle(.green/.yellow/.red)` 대체.
struct StatusLabel: View {
    let text: String
    let systemImage: String
    var tone: SeedTone = .neutral

    init(_ text: String, systemImage: String, tone: SeedTone = .neutral) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(tone.fg)
    }
}
