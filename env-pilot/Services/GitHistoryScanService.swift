import Foundation
import zlib

/// Git 히스토리에 커밋된 적 있는 .env 파일 탐지 (Health 탭).
/// 현재 tracked 여부와 무관하게, 과거 커밋의 tree에 .env가 남아 있으면 secret이
/// 히스토리에 노출된 상태다 — git rm으로는 지워지지 않는다.
/// ponytail: git CLI는 샌드박스 자식 프로세스 권한 문제로 미사용(GitSafetyService 참고).
/// loose object와 packfile을 직접 inflate해 tree entry에서 .env 파일명을 찾는다.
/// delta object는 바이트 패턴 검색 휴리스틱 — alternates/멀티팩 미지원, 필요해지면 확장.
enum GitHistoryScanService {

    /// 히스토리 스캔 결과. 스캔은 pack 전체 inflate라 비싸다 — fingerprint로 캐시.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (fingerprint: String, names: [String])] = [:]

    /// Git 저장소가 아니면 nil. 발견된 .env 파일명(중복 제거, 정렬)을 반환.
    static func scan(rootURL: URL) -> [String]? {
        let hasAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { rootURL.stopAccessingSecurityScopedResource() } }
        guard let gitDir = GitInfo.gitDirectory(of: rootURL) else { return nil }

        let objectsDir = gitDir.appendingPathComponent("objects")
        let fingerprint = objectsFingerprint(objectsDir)
        cacheLock.lock()
        let cached = cache[gitDir.path]
        cacheLock.unlock()
        if let cached, cached.fingerprint == fingerprint { return cached.names }

        var found = Set<String>()
        scanLooseObjects(objectsDir, into: &found)
        scanPacks(objectsDir.appendingPathComponent("pack"), into: &found)

        let names = found.sorted()
        cacheLock.lock()
        cache[gitDir.path] = (fingerprint, names)
        cacheLock.unlock()
        return names
    }

    /// objects 디렉토리의 pack 파일명·크기와 loose 디렉토리 목록으로 변경 감지.
    private static func objectsFingerprint(_ objectsDir: URL) -> String {
        let fm = FileManager.default
        var parts: [String] = []
        let packDir = objectsDir.appendingPathComponent("pack")
        for name in ((try? fm.contentsOfDirectory(atPath: packDir.path)) ?? []).sorted() {
            let size = (try? fm.attributesOfItem(atPath: packDir.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? 0
            parts.append("\(name):\(size)")
        }
        for sub in ((try? fm.contentsOfDirectory(atPath: objectsDir.path)) ?? []).sorted() where sub.count == 2 {
            let files = (try? fm.contentsOfDirectory(atPath: objectsDir.appendingPathComponent(sub).path)) ?? []
            parts.append("\(sub):\(files.count)")
        }
        return parts.joined(separator: "|")
    }

    // MARK: - loose objects (.git/objects/ab/cdef...)

    private static func scanLooseObjects(_ objectsDir: URL, into found: inout Set<String>) {
        let fm = FileManager.default
        for sub in (try? fm.contentsOfDirectory(atPath: objectsDir.path)) ?? [] {
            guard sub.count == 2, sub.allSatisfy(\.isHexDigit) else { continue }
            let dir = objectsDir.appendingPathComponent(sub)
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(file), options: .mappedIfSafe),
                      let (inflated, _) = inflate(data, from: 0),
                      inflated.starts(with: Array("tree ".utf8)),
                      let nul = inflated.firstIndex(of: 0)
                else { continue }
                collectTreeEntries(inflated[inflated.index(after: nul)...], into: &found)
            }
        }
    }

    // MARK: - packfiles (.git/objects/pack/*.pack)

    private static func scanPacks(_ packDir: URL, into found: inout Set<String>) {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: packDir.path)) ?? [] where file.hasSuffix(".pack") {
            guard let data = try? Data(contentsOf: packDir.appendingPathComponent(file), options: .mappedIfSafe)
            else { continue }
            scanPack(data, into: &found)
        }
    }

    /// pack v2 포맷: 12바이트 헤더 후 object가 연속. 각 object는 (type+size varint)
    /// [+ delta base 정보] + zlib 스트림. 다음 object 위치를 알려면 스트림을 끝까지
    /// 소비해야 하므로 전체 inflate가 불가피하다.
    static func scanPack(_ data: Data, into found: inout Set<String>) {
        guard data.count > 32, data.prefix(4) == Data("PACK".utf8) else { return }
        let count = data.subdata(in: 8..<12).reduce(0) { $0 << 8 | Int($1) }
        var offset = 12

        for _ in 0..<count {
            guard offset < data.count - 20 else { return }  // 마지막 20바이트는 pack checksum
            var byte = data[offset]; offset += 1
            let type = (byte >> 4) & 0x7
            while byte & 0x80 != 0, offset < data.count {
                byte = data[offset]; offset += 1
            }
            if type == 6 {  // OFS_DELTA: base offset varint
                repeat {
                    guard offset < data.count else { return }
                    byte = data[offset]; offset += 1
                } while byte & 0x80 != 0
            } else if type == 7 {  // REF_DELTA: 20바이트 base sha
                offset += 20
            }
            // ponytail: tree(2)·delta(6,7)만 본문이 필요. blob/commit/tag는 offset 전진용으로 스트림만
            // 소비하고 저장 생략(outputLimit 0) — 대형 pack에서 blob 복사가 메모리·CPU의 대부분이라 이게 큰 절감.
            let needsBody = type == 2 || type == 6 || type == 7
            guard let (body, consumed) = inflate(data, from: offset,
                                                 outputLimit: needsBody ? 8 << 20 : 0) else { return }
            offset += consumed

            if type == 2 {  // tree — 정식 파싱
                collectTreeEntries(body[...], into: &found)
            } else if type == 6 || type == 7 {
                // ponytail: delta는 base type을 모르므로(idx 체인 필요) 삽입 데이터에서
                // tree entry 패턴(" .env…\0")을 휴리스틱 검색. blob 오탐은 NUL 요건으로 걸러진다.
                collectHeuristicMatches(body, into: &found)
            }
        }
    }

    // MARK: - tree entry 파싱

    /// tree body는 "<mode> <name>\0<20바이트 sha>" 반복.
    static func collectTreeEntries(_ body: Data.SubSequence, into found: inout Set<String>) {
        var i = body.startIndex
        while i < body.endIndex {
            guard let space = body[i...].firstIndex(of: 0x20),
                  let nul = body[space...].firstIndex(of: 0)
            else { return }
            if let name = String(data: body[body.index(after: space)..<nul], encoding: .utf8),
               isEnvName(name) {
                found.insert(name)
            }
            guard let next = body.index(nul, offsetBy: 21, limitedBy: body.endIndex) else { return }
            i = next
        }
    }

    /// delta 데이터에서 " .env<suffix>\0" 패턴 검색 — mode 뒤 공백과 이름 뒤 NUL이 판별 기준.
    static func collectHeuristicMatches(_ data: Data, into found: inout Set<String>) {
        let marker = Data(" .env".utf8)
        var searchFrom = data.startIndex
        while let range = data.range(of: marker, in: searchFrom..<data.endIndex) {
            searchFrom = data.index(after: range.lowerBound)
            let nameStart = data.index(after: range.lowerBound)
            let limit = data.index(nameStart, offsetBy: 64, limitedBy: data.endIndex) ?? data.endIndex
            guard let nul = data[nameStart..<limit].firstIndex(of: 0),
                  let name = String(data: data[nameStart..<nul], encoding: .utf8),
                  isEnvName(name)
            else { continue }
            found.insert(name)
        }
    }

    /// pre-commit hook과 동일 기준: .env 또는 .env.*, example/sample 제외.
    static func isEnvName(_ name: String) -> Bool {
        guard name == ".env" || name.hasPrefix(".env.") else { return false }
        return !name.hasSuffix(".example") && !name.hasSuffix(".sample")
            && !name.contains("/") && name.allSatisfy { !$0.isNewline }
    }

    // MARK: - zlib inflate

    /// offset부터 zlib 스트림 하나를 inflate. (본문, 소비한 입력 바이트 수) 반환.
    /// 손상된 스트림이면 nil — pack 순회는 그 지점에서 중단된다.
    static func inflate(_ data: Data, from offset: Int, outputLimit: Int = 8 << 20) -> (Data, Int)? {
        guard offset < data.count else { return nil }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var status: Int32 = Z_OK

        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(
                mutating: src.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self))
            stream.avail_in = uInt(data.count - offset)
            while status == Z_OK {
                buffer.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(buf.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    let produced = buf.count - Int(stream.avail_out)
                    // 다음 object 위치 계산을 위해 스트림은 끝까지 소비하되, 저장은 limit까지만
                    if produced > 0 && output.count < outputLimit {
                        output.append(buf.baseAddress!, count: produced)
                    }
                }
                if status == Z_OK && stream.avail_in == 0 && stream.avail_out > 0 {
                    status = Z_BUF_ERROR  // 입력이 끝났는데 스트림이 안 끝남 — 손상
                }
            }
        }
        guard status == Z_STREAM_END else { return nil }
        return (output, Int(stream.total_in))
    }
}
