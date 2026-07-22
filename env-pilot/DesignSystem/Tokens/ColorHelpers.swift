// 디자인 시스템 공용 컬러 헬퍼. DesignSystem/ 내 유일한 AppKit 의존 지점.

import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension Color {
    /// 라이트/다크 hex(0xRRGGBBAA)로 시스템 외형을 자동 추적하는 동적 컬러 생성.
    init(light: UInt32, dark: UInt32) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(srgbRGBA: isDark ? dark : light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(srgbRGBA: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

#if canImport(AppKit)
private extension NSColor {
    convenience init(srgbRGBA rgba: UInt32) {
        self.init(
            srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }
}
#else
private extension UIColor {
    convenience init(srgbRGBA rgba: UInt32) {
        self.init(
            red: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }
}
#endif
