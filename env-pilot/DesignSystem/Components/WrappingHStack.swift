import SwiftUI

/// 단순 줄바꿈 HStack 대체 — 항목이 많으면 여러 줄로.
struct WrappingHStack<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        FlowLayout(spacing: SeedSpacing.x1) { content }
    }
}

/// 항목을 이상적 크기 그대로 두고 줄 단위로 흘리는 최소 flow layout.
/// (LazyVGrid adaptive는 셀 폭에 맞춰 칩 내부 텍스트를 줄바꿈시켜 부적합)
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let offsets = arrange(subviews, maxWidth: bounds.width).offsets
        for (subview, offset) in zip(subviews, offsets) {
            subview.place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                          proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x + size.width)
            x += size.width + spacing
        }
        return (offsets, CGSize(width: maxX, height: y + rowHeight))
    }
}
