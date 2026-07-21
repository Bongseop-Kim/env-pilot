import SwiftUI

/// 단순 줄바꿈 HStack 대체 — 항목이 많으면 여러 줄로.
struct WrappingHStack<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        // ponytail: FlowLayout 대신 LazyVGrid — 충분히 읽히고 코드가 짧다
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                  alignment: .leading, spacing: SeedSpacing.x1) {
            content
        }
    }
}
