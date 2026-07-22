// 디자인 시스템 토큰 스모크 체크 — 생성 스크립트 회귀 감지.
// 실행: swiftc -parse-as-library env-pilot/DesignSystem/Tokens/*.swift env-pilot/DesignSystem/Components/SeedTone.swift Tests/DesignSystemChecks.swift -o /tmp/ds-check && /tmp/ds-check

import SwiftUI

@main
struct DesignSystemChecks {
    static func main() {
        // rootage 원본 값과 대조한 대표 스칼라 (seed-design packages/rootage)
        assert(SeedSpacing.x1 == 4 && SeedSpacing.x4 == 16 && SeedSpacing.x16 == 64)
        assert(SeedRadius.r2 == 8 && SeedRadius.full == 9999)
        assert(SeedFontSize.t1 == 11 && SeedFontSize.t4 == 14 && SeedFontSize.t14 == 48)
        assert(SeedDuration.d3 == 0.15 && SeedDuration.colorTransition == 0.15)
        assert(SeedScale.s97 == 0.97)
        assert(SeedShadow.s3.blur == 16 && SeedShadow.s3.y == 4)

        // 동적 컬러 생성 스모크 (dynamicProvider 크래시 없이 해석되는지)
        let env = EnvironmentValues()
        let brand = SeedColor.bgBrandSolid.resolve(in: env)
        assert(brand.red > 0.9 && brand.blue < 0.1, "carrot 오렌지가 아님: \(brand)")
        _ = SeedTone.critical.bgWeak.resolve(in: env)

        print("DesignSystemChecks OK")
    }
}
