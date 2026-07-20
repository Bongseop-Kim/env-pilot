// EnvParser 자체 검증 (PRD §3.2 수용 기준).
// 실행: swiftc -parse-as-library env-pilot/Services/EnvParser.swift Tests/EnvParserChecks.swift -o /tmp/envparser-check && /tmp/envparser-check
// ponytail: 테스트 타깃 없이 swiftc 단독 실행 — Xcode 테스트 타깃 추가 시 Swift Testing으로 이전

import Foundation

@main
struct EnvParserChecks {
    static var failures = 0

    static func expect(_ input: String, _ key: String, _ value: String, line: Int = #line) {
        let got = EnvParser.parse(input).entries.first { $0.key == key }?.value
        if got != value {
            failures += 1
            print("❌ L\(line): parse(\(input.debugDescription))[\(key)] == \(got.debugDescription), expected \(value.debugDescription)")
        }
    }

    static func check(_ cond: Bool, _ desc: String, line: Int = #line) {
        if !cond { failures += 1; print("❌ L\(line): \(desc)") }
    }

    static func main() {
        // PRD 파싱 규칙 표
        expect("KEY=value", "KEY", "value")
        expect("export KEY=value", "KEY", "value")
        expect("KEY=\"va lue\"", "KEY", "va lue")
        expect("KEY='va lue'", "KEY", "va lue")
        expect(#"KEY="a\"b\nc""#, "KEY", "a\"b\nc")                 // double quote 이스케이프
        expect(#"KEY='a\nb'"#, "KEY", #"a\nb"#)                     // single quote는 이스케이프 없음
        expect("KEY=a=b=c", "KEY", "a=b=c")                          // 첫 = 기준 분리
        expect("KEY=value # comment", "KEY", "value")                // 인라인 주석
        expect("KEY=abc#def", "KEY", "abc#def")                      // 공백 없는 #은 값의 일부
        expect("KEY=\"value\" # comment", "KEY", "value")            // 닫는 따옴표 이후 무시
        expect("KEY=", "KEY", "")                                    // 빈 값도 유효
        expect("  KEY = value  ", "KEY", "value")                    // 공백 트림
        expect("\u{FEFF}KEY=value", "KEY", "value")                  // BOM 제거
        expect("KEY=1\nKEY=2", "KEY", "2")                           // 중복 키: 마지막 값

        let mixed = EnvParser.parse("# comment\n\nA=1\n잘못된 줄\n1BAD=x\nB=2\n")
        check(mixed.entries == [.init(key: "A", value: "1"), .init(key: "B", value: "2")],
              "주석/빈 줄 무시, 유효 항목만 순서대로")
        check(mixed.warnings.count == 2, "'=' 없는 줄과 잘못된 키가 경고로 수집 (got \(mixed.warnings))")
        check(EnvParser.parse("KEY=\"unterminated").warnings.count == 1, "닫히지 않은 따옴표 경고")

        // 직렬화: 정렬, 필요 시 quoting, 끝 개행
        let out = EnvParser.serialize(["B_KEY": "plain", "A_KEY": "has space", "C": ""])
        check(out == "A_KEY=\"has space\"\nB_KEY=plain\nC=\n", "직렬화 형식 (got \(out.debugDescription))")

        // 라운드트립: parse(serialize(x)) == x
        let tricky: [String: String] = [
            "PLAIN": "value", "EMPTY": "", "SPACES": "  padded  ", "HASH": "a # b",
            "QUOTE": "say \"hi\"", "NEWLINE": "line1\nline2", "TAB": "a\tb",
            "BACKSLASH": #"C:\path\n"#, "EQUALS": "a=b=c", "URL": "postgres://u:p@h:5432/db",
        ]
        let parsed = EnvParser.parse(EnvParser.serialize(tricky))
        let roundTripped = Dictionary(uniqueKeysWithValues: parsed.entries.map { ($0.key, $0.value) })
        check(roundTripped == tricky, "라운드트립 보존 (diff: \(tricky.keys.filter { tricky[$0] != roundTripped[$0] }))")
        check(parsed.warnings.isEmpty, "직렬화 출력은 경고 없이 파싱됨 (got \(parsed.warnings))")

        if failures == 0 {
            print("✅ EnvParser: all checks passed")
        } else {
            print("💥 \(failures) failure(s)")
            exit(1)
        }
    }
}
