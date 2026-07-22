import SwiftUI

/// seed semantic typography의 데스크톱 축소판.
/// ponytail: seed 34종 중 실사용 role만, macOS 밀도(본문 13pt)로 재보정 — seed rem 값은 모바일 웹 기준.
/// lineHeight/letterSpacing 토큰은 스킵 — 여러 줄 본문이 생기면 ViewModifier로 추가.
enum SeedTypography {
    static let title = SeedFont.t6(.bold)        // 18 — 시트/화면 제목
    static let sectionBold = SeedFont.t4(.bold)  // 14 — 섹션 헤더, 주요 버튼
    static let section = SeedFont.t4(.medium)    // 14 — 필드 라벨, 강조 텍스트
    static let bodyLarge = SeedFont.t4()         // 14 — 시트 입력 필드, 콜아웃, 스낵바
    static let body = SeedFont.t3()              // 13 — 기본 본문, 모든 리스트 행 (macOS 표준)
    static let bodyBold = SeedFont.t3(.bold)     // 13 — 본문 강조
    static let label = SeedFont.t2()             // 12 — 보조 라벨
    static let caption = SeedFont.t1()           // 11 — 메타/캡션
}
