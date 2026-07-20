// MonorepoScanner 검증 (PRD §3.5).
// 실행: swiftc -parse-as-library env-pilot/Services/MonorepoScanner.swift Tests/MonorepoScannerChecks.swift -o /tmp/monorepo-check && /tmp/monorepo-check

import Foundation

@main
struct MonorepoScannerChecks {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("monorepo-check-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: base) }

        func makePackage(_ root: URL, _ path: String, example: Bool = false) throws {
            let dir = root.appendingPathComponent(path)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{}".write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            if example {
                try "API_KEY=".write(to: dir.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
            }
        }

        // pnpm workspace
        let pnpm = base.appendingPathComponent("pnpm-repo")
        try fm.createDirectory(at: pnpm, withIntermediateDirectories: true)
        try """
        packages:
          - "apps/*"
          - services/api
          - "!apps/legacy"
        """.write(to: pnpm.appendingPathComponent("pnpm-workspace.yaml"), atomically: true, encoding: .utf8)
        try makePackage(pnpm, "apps/shop", example: true)
        try makePackage(pnpm, "apps/admin")
        try fm.createDirectory(at: pnpm.appendingPathComponent("apps/no-pkg"), withIntermediateDirectories: true)  // package.json 없음
        try makePackage(pnpm, "services/api")
        try makePackage(pnpm, "node_modules/evil")
        // 심볼릭 링크는 무시
        try fm.createSymbolicLink(at: pnpm.appendingPathComponent("apps/linked"),
                                  withDestinationURL: pnpm.appendingPathComponent("services/api"))

        let pnpmResult = MonorepoScanner.scan(rootURL: pnpm)
        assert(pnpmResult.map(\.relativePath) == ["apps/admin", "apps/shop", "services/api"],
               "pnpm 후보 (got \(pnpmResult.map(\.relativePath)))")
        assert(pnpmResult.first { $0.relativePath == "apps/shop" }?.hasExample == true, "example 감지")
        assert(pnpmResult.first { $0.relativePath == "apps/admin" }?.hasExample == false, "example 없음")

        // package.json workspaces (yarn/npm/turbo/nx)
        let npm = base.appendingPathComponent("npm-repo")
        try fm.createDirectory(at: npm, withIntermediateDirectories: true)
        try #"{"workspaces": ["packages/**"]}"#.write(
            to: npm.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try makePackage(npm, "packages/core")
        let npmResult = MonorepoScanner.scan(rootURL: npm)
        assert(npmResult.map(\.relativePath) == ["packages/core"], "npm workspaces (got \(npmResult.map(\.relativePath)))")

        // 모노레포 아님 → 빈 결과 (§3.5: 루트 Target 하나만 유지)
        let plain = base.appendingPathComponent("plain")
        try makePackage(plain, ".")
        assert(MonorepoScanner.scan(rootURL: plain).isEmpty, "비모노레포는 후보 없음")

        print("✅ MonorepoScanner: all checks passed")
    }
}
