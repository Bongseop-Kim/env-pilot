// seed-design rootage(dimension/radius/font/duration/timing-function/scale/shadow.json)에서 이식한 토큰. seed 스펙과 어긋나지 않게 값 수정 주의.

import SwiftUI

/// 4px 그리드 간격 (x1 = 4pt)
enum SeedSpacing {
    static let x0_5: CGFloat = 2
    static let x1: CGFloat = 4
    static let x1_5: CGFloat = 6
    static let x2: CGFloat = 8
    static let x2_5: CGFloat = 10
    static let x3: CGFloat = 12
    static let x3_5: CGFloat = 14
    static let x4: CGFloat = 16
    static let x4_5: CGFloat = 18
    static let x5: CGFloat = 20
    static let x6: CGFloat = 24
    static let x7: CGFloat = 28
    static let x8: CGFloat = 32
    static let x9: CGFloat = 36
    static let x10: CGFloat = 40
    static let x12: CGFloat = 48
    static let x13: CGFloat = 52
    static let x14: CGFloat = 56
    static let x16: CGFloat = 64
}

enum SeedRadius {
    static let r0_5: CGFloat = 2
    static let r1: CGFloat = 4
    static let r1_5: CGFloat = 6
    static let r2: CGFloat = 8
    static let r2_5: CGFloat = 10
    static let r3: CGFloat = 12
    static let r3_5: CGFloat = 14
    static let r4: CGFloat = 16
    static let r5: CGFloat = 20
    static let r6: CGFloat = 24
    static let full: CGFloat = 9999
}

enum SeedFontSize {
    static let t1: CGFloat = 11
    static let t2: CGFloat = 12
    static let t3: CGFloat = 13
    static let t4: CGFloat = 14
    static let t5: CGFloat = 16
    static let t6: CGFloat = 18
    static let t7: CGFloat = 20
    static let t8: CGFloat = 22
    static let t9: CGFloat = 24
    static let t10: CGFloat = 26
    static let t11: CGFloat = 28
    static let t12: CGFloat = 32
    static let t13: CGFloat = 40
    static let t14: CGFloat = 48
}

enum SeedFont {
    static func t1(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t1, weight: weight) }
    static func t2(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t2, weight: weight) }
    static func t3(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t3, weight: weight) }
    static func t4(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t4, weight: weight) }
    static func t5(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t5, weight: weight) }
    static func t6(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t6, weight: weight) }
    static func t7(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t7, weight: weight) }
    static func t8(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t8, weight: weight) }
    static func t9(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t9, weight: weight) }
    static func t10(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t10, weight: weight) }
    static func t11(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t11, weight: weight) }
    static func t12(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t12, weight: weight) }
    static func t13(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t13, weight: weight) }
    static func t14(_ weight: Font.Weight = .regular) -> Font { .system(size: SeedFontSize.t14, weight: weight) }
}

enum SeedFontWeight {
    static let regular: Font.Weight = .regular
    static let medium: Font.Weight = .medium
    static let bold: Font.Weight = .bold
}

enum SeedDuration {
    static let d1: TimeInterval = 0.05
    static let d2: TimeInterval = 0.1
    static let d3: TimeInterval = 0.15
    static let d4: TimeInterval = 0.2
    static let d5: TimeInterval = 0.25
    static let d6: TimeInterval = 0.3
    static let colorTransition: TimeInterval = 0.15
    static let pressedScale: TimeInterval = 0.15
}

enum SeedEasing {
    static func linear(_ duration: TimeInterval = SeedDuration.d5) -> Animation { .timingCurve(0, 0, 1, 1, duration: duration) }
    static func easing(_ duration: TimeInterval = SeedDuration.colorTransition) -> Animation { .timingCurve(0.35, 0, 0.35, 1, duration: duration) }
    static func enter(_ duration: TimeInterval = SeedDuration.d5) -> Animation { .timingCurve(0, 0, 0.15, 1, duration: duration) }
    static func exit(_ duration: TimeInterval = SeedDuration.d5) -> Animation { .timingCurve(0.35, 0, 1, 1, duration: duration) }
    static func enterExpressive(_ duration: TimeInterval = SeedDuration.d5) -> Animation { .timingCurve(0.03, 0.4, 0.1, 1, duration: duration) }
    static func exitExpressive(_ duration: TimeInterval = SeedDuration.d5) -> Animation { .timingCurve(0.35, 0, 0.95, 0.55, duration: duration) }
    static func pressedScale(_ duration: TimeInterval = SeedDuration.pressedScale) -> Animation { .timingCurve(0, 0, 0.15, 1, duration: duration) }
}

/// 눌림 스케일 (reduced motion 시 컴포넌트에서 accessibilityReduceMotion으로 1.0 처리)
enum SeedScale {
    static let s95: CGFloat = 0.95
    static let s97: CGFloat = 0.97
    static let s98: CGFloat = 0.98
}

struct SeedShadowToken {
    let color: Color
    let y: CGFloat
    let blur: CGFloat
}

enum SeedShadow {
    static let s1 = SeedShadowToken(color: Color(light: 0x00000014, dark: 0x00000080), y: 1, blur: 4)
    static let s2 = SeedShadowToken(color: Color(light: 0x0000001A, dark: 0x000000AD), y: 2, blur: 10)
    static let s3 = SeedShadowToken(color: Color(light: 0x0000001F, dark: 0x000000CC), y: 4, blur: 16)
}

extension View {
    /// seed 그림자 (CSS blur → SwiftUI radius 근사: blur/2)
    func seedShadow(_ token: SeedShadowToken) -> some View {
        shadow(color: token.color, radius: token.blur / 2, y: token.y)
    }
}
