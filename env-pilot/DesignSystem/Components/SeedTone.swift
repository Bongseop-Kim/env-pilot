import SwiftUI

/// seed 시맨틱 컬러의 Role 축 — 컴포넌트(뱃지·콜아웃·상태 라벨)가 공유하는 톤.
enum SeedTone {
    case neutral, brand, positive, warning, critical, informative

    var fg: Color {
        switch self {
        case .neutral: SeedColor.fgNeutral
        case .brand: SeedColor.fgBrand
        case .positive: SeedColor.fgPositive
        case .warning: SeedColor.fgWarning
        case .critical: SeedColor.fgCritical
        case .informative: SeedColor.fgInformative
        }
    }

    var bgWeak: Color {
        switch self {
        case .neutral: SeedColor.bgNeutralWeak
        case .brand: SeedColor.bgBrandWeak
        case .positive: SeedColor.bgPositiveWeak
        case .warning: SeedColor.bgWarningWeak
        case .critical: SeedColor.bgCriticalWeak
        case .informative: SeedColor.bgInformativeWeak
        }
    }

    var bgSolid: Color {
        switch self {
        case .neutral: SeedColor.bgNeutralSolid
        case .brand: SeedColor.bgBrandSolid
        case .positive: SeedColor.bgPositiveSolid
        case .warning: SeedColor.bgWarningSolid
        case .critical: SeedColor.bgCriticalSolid
        case .informative: SeedColor.bgInformativeSolid
        }
    }

    var strokeWeak: Color {
        switch self {
        case .neutral: SeedColor.strokeNeutralMuted
        case .brand: SeedColor.strokeBrandWeak
        case .positive: SeedColor.strokePositiveWeak
        case .warning: SeedColor.strokeWarningWeak
        case .critical: SeedColor.strokeCriticalWeak
        case .informative: SeedColor.strokeInformativeWeak
        }
    }
}
