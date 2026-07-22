import SwiftUI

/// seed 시맨틱 컬러의 Role 축 — 컴포넌트(콜아웃·상태 라벨)가 공유하는 톤.
enum SeedTone {
    case neutral, positive, warning, critical

    var fg: Color {
        switch self {
        case .neutral: SeedColor.fgNeutral
        case .positive: SeedColor.fgPositive
        case .warning: SeedColor.fgWarning
        case .critical: SeedColor.fgCritical
        }
    }

    var bgWeak: Color {
        switch self {
        case .neutral: SeedColor.bgNeutralWeak
        case .positive: SeedColor.bgPositiveWeak
        case .warning: SeedColor.bgWarningWeak
        case .critical: SeedColor.bgCriticalWeak
        }
    }
}
