import Foundation

/// .env 파일 파서/직렬화기. PRD §3.2.
/// 파싱은 key/value 추출, 직렬화는 앱 데이터로부터의 신규 생성 — 원문 포맷 보존은 하지 않는다.
enum EnvParser {

    struct Entry: Equatable {
        var key: String
        var value: String
    }

    struct ParseResult: Equatable {
        var entries: [Entry] = []       // 파일 등장 순서, 중복 키는 마지막 값이 남음
        var warnings: [String] = []
    }

    /// 키 유효성: [A-Za-z_][A-Za-z0-9_]*
    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter && first.isASCII || first == "_" else { return false }
        return key.dropFirst().allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "_" }
    }

    // MARK: - Parse

    static func parse(_ content: String) -> ParseResult {
        var result = ParseResult()
        var indexByKey: [String: Int] = [:]

        let text = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content

        for (lineNumber, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\r") { line = String(line.dropLast()) }
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }

            guard let eq = line.firstIndex(of: "=") else {
                result.warnings.append("line \(lineNumber + 1): '=' 없음 — 무시됨: \(line)")
                continue
            }

            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard isValidKey(key) else {
                result.warnings.append("line \(lineNumber + 1): 잘못된 키 이름 — 무시됨: \(key)")
                continue
            }

            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let value = parseValue(rawValue, lineNumber: lineNumber + 1, warnings: &result.warnings)

            if let existing = indexByKey[key] {
                result.entries[existing].value = value
                result.warnings.append("line \(lineNumber + 1): 중복 키 \(key) — 마지막 값 사용")
            } else {
                indexByKey[key] = result.entries.count
                result.entries.append(Entry(key: key, value: value))
            }
        }
        return result
    }

    private static func parseValue(_ raw: String, lineNumber: Int, warnings: inout [String]) -> String {
        if raw.isEmpty { return "" }

        if raw.hasPrefix("\"") {
            var value = ""
            var chars = raw.dropFirst().makeIterator()
            while let c = chars.next() {
                if c == "\\" {
                    guard let next = chars.next() else { value.append(c); break }
                    switch next {
                    case "\"": value.append("\"")
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    case "\\": value.append("\\")
                    default: value.append(c); value.append(next)  // 알 수 없는 이스케이프는 원문 유지
                    }
                } else if c == "\"" {
                    return value  // 닫는 따옴표 이후는 무시 (주석 등)
                } else {
                    value.append(c)
                }
            }
            warnings.append("line \(lineNumber): 닫히지 않은 따옴표")
            return value
        }

        if raw.hasPrefix("'") {
            let body = raw.dropFirst()
            if let close = body.firstIndex(of: "'") {
                return String(body[..<close])  // single quote는 이스케이프 없음, 이후 무시
            }
            warnings.append("line \(lineNumber): 닫히지 않은 따옴표")
            return String(body)
        }

        // 따옴표 없는 값: 공백 뒤 '#'부터 주석
        var value = raw
        var searchStart = value.startIndex
        while let hash = value[searchStart...].firstIndex(of: "#") {
            if hash == value.startIndex || value[value.index(before: hash)].isWhitespace {
                value = String(value[..<hash])
                break
            }
            searchStart = value.index(after: hash)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Serialize

    static func serialize(_ variables: [String: String]) -> String {
        var lines = variables.keys.sorted().map { key -> String in
            let value = variables[key]!
            return "\(key)=\(quoteIfNeeded(value))"
        }
        lines.append("")  // 파일 끝 개행
        return lines.joined(separator: "\n")
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let needsQuoting = value.contains { $0 == "#" || $0 == "\"" || $0 == "\\" || $0.isWhitespace }
            || value.hasPrefix("'")
        guard needsQuoting else { return value }

        var escaped = ""
        for c in value {
            switch c {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(c)
            }
        }
        return "\"\(escaped)\""
    }
}
