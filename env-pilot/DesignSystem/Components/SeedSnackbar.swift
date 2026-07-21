import SwiftUI

/// seed snackbar 포팅 — 하단 플로팅 임시 알림. 2.5초 후 자동 소멸.
struct SeedSnackbarMessage: Equatable {
    let text: String
    var tone: SeedTone = .neutral   // positive/critical이면 앞에 아이콘 표시

    init(_ text: String, tone: SeedTone = .neutral) {
        self.text = text
        self.tone = tone
    }
}

extension View {
    /// `@State var snackbar: SeedSnackbarMessage?`에 연결.
    func snackbar(_ message: Binding<SeedSnackbarMessage?>) -> some View {
        overlay(alignment: .bottom) {
            if let current = message.wrappedValue {
                SeedSnackbarView(message: current)
                    .padding(SeedSpacing.x2)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .task(id: current) {
                        try? await Task.sleep(for: .seconds(2.5))
                        message.wrappedValue = nil
                    }
            }
        }
        .animation(SeedEasing.enter(SeedDuration.d3), value: message.wrappedValue)
    }
}

private struct SeedSnackbarView: View {
    let message: SeedSnackbarMessage

    var body: some View {
        HStack(spacing: SeedSpacing.x2) {
            switch message.tone {
            case .positive:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(SeedColor.fgPositive)
            case .critical:
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(SeedColor.fgCritical)
            default:
                EmptyView()
            }
            Text(message.text)
                .font(SeedFont.t4())
                .foregroundStyle(SeedColor.fgNeutralInverted)
        }
        .padding(.horizontal, SeedSpacing.x4)
        .padding(.vertical, SeedSpacing.x2_5)
        .frame(minHeight: 40)
        .background(SeedColor.bgNeutralInverted, in: .rect(cornerRadius: SeedRadius.r2))
        .seedShadow(SeedShadow.s2)
    }
}
