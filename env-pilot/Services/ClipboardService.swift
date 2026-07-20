import AppKit

/// 클립보드 복사 (PRD §3.16) — Secret 포함 시 30초 후 자동 삭제.
enum ClipboardService {
    static let clearDelay: TimeInterval = 30

    /// clearAfterDelay: 30초 뒤 changeCount가 그대로면(사용자가 다른 것을 복사하지 않았으면) 클립보드를 비운다.
    static func copy(_ text: String, clearAfterDelay: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard clearAfterDelay else { return }
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay) {
            if pasteboard.changeCount == count {
                pasteboard.clearContents()
            }
        }
    }
}

/// "Copy as…" 포맷 (PRD §3.20).
enum CopyFormat: String, CaseIterable {
    case dotenv = "dotenv"
    case shell = "Shell exports"
    case json = "JSON"

    func render(_ values: [String: String]) -> String {
        switch self {
        case .dotenv:
            return EnvParser.serialize(values)
        case .shell:
            return values.keys.sorted()
                .map { "export \($0)=\"\(Self.shellEscape(values[$0]!))\"" }
                .joined(separator: "\n") + "\n"
        case .json:
            let data = try! JSONSerialization.data(
                withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8)!
        }
    }

    /// 쉘 큰따옴표 안에서 특수 의미인 문자만 이스케이프.
    private static func shellEscape(_ value: String) -> String {
        var out = ""
        for c in value {
            if c == "\\" || c == "\"" || c == "$" || c == "`" { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
