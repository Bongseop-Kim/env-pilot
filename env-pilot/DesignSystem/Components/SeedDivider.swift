import SwiftUI

/// seed divider — 1pt stroke-neutral-muted 수평선.
struct SeedDivider: View {
    var body: some View {
        Rectangle()
            .fill(SeedColor.strokeNeutralMuted)
            .frame(height: 1)
    }
}
