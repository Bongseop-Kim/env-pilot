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

    /// 인증 통과 여부. 설정 off / 60초 grace 내 / 인증 수단 없음이면 즉시 true.
    static func authorize(reason: String) async -> Bool {
        guard isEnabled else { return true }
        // ponytail: 60초 grace — 연속 복사마다 Touch ID를 요구하면 못 쓴다
        if let last = lastSuccess, Date().timeIntervalSince(last) < graceInterval { return true }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
        else { return false }
        lastSuccess = Date()
        return true
    }
}
