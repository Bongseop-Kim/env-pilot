import SwiftUI

/// seed text-input(outline/medium) 포팅 — 시트/폼 필드용. 리스트 행 인라인 편집은 네이티브 .plain 유지.
struct SeedTextField: View {
    let title: String
    @Binding var text: String
    var isInvalid = false
    var secure = false

    @FocusState private var focused: Bool

    init(_ title: String, text: Binding<String>, isInvalid: Bool = false, secure: Bool = false) {
        self.title = title
        self._text = text
        self.isInvalid = isInvalid
        self.secure = secure
    }

    var body: some View {
        Group {
            if secure {
                SecureField(title, text: $text)
            } else {
                TextField(title, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(SeedFont.t4())
        .focused($focused)
        .padding(.horizontal, SeedSpacing.x3_5)
        .frame(minHeight: SeedSpacing.x10)
        .overlay {
            RoundedRectangle(cornerRadius: SeedRadius.r2)
                .strokeBorder(strokeColor, lineWidth: focused || isInvalid ? 2 : 1)
        }
        .animation(SeedEasing.easing(), value: focused)
    }

    private var strokeColor: Color {
        if isInvalid { return SeedColor.strokeCriticalSolid }
        return focused ? SeedColor.strokeNeutralContrast : SeedColor.strokeNeutralWeak
    }
}
