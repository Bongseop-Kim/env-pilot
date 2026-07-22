import Foundation
import LocalAuthentication

/// Secret 표시/복사/해제 전 사용자 인증 — 1Password식 "사용당 승인" 모델.
/// Touch ID 우선, 없으면 로그인 비밀번호 폴백.
enum BiometricGate {
    static let settingKey = "requireAuthForSecrets"
    static let graceInterval: TimeInterval = 60
    private static var lastSuccess: Date?

    /// 기본값 on — @AppStorage(settingKey) 토글과 같은 키를 읽는다.
    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: settingKey) as? Bool) ?? true
    }

    /// 남은 grace 시간(초). 이 시간 동안은 재인증 없이 통과한다 — 툴바 카운트다운 표시용.
    static func graceRemaining(at date: Date = Date()) -> TimeInterval {
        guard isEnabled, let last = lastSuccess else { return 0 }
        return max(0, graceInterval - date.timeIntervalSince(last))
    }

    /// grace를 지금부터 다시 60초로 채운다 — 툴바 배지의 연장 액션용.
    static func extendGrace() { lastSuccess = Date() }

    /// 인증 통과 여부. 설정 off / 60초 grace 내 / 인증 수단 없음이면 즉시 true.
    static func authorize(reason: String) async -> Bool {
        guard isEnabled else { return true }
        // ponytail: 60초 grace — 연속 복사마다 Touch ID를 요구하면 못 쓴다
        if graceRemaining() > 0 { return true }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
        else { return false }
        lastSuccess = Date()
        return true
    }
}
