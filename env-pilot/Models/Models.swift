import Foundation
import SwiftData

// PRD §2.2 — SwiftData 엔티티.
// CloudKit 동기화 전제: 모든 프로퍼티는 optional 또는 기본값, @Attribute(.unique) 사용 불가,
// 관계는 optional. 유니크 제약(§2.2)은 저장 전 애플리케이션 레벨에서 검사한다.

@Model
final class Workspace {
    var name: String = "Default"
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \Repository.workspace)
    var repositories: [Repository]? = []

    init(name: String = "Default") {
        self.name = name
    }
}

/// 구버전 저장 데이터와 .envide v1 번들 호환용. 신규 UI와 파일 동기화에서는 사용하지 않는다.
@Model
final class EnvEnvironment {
    var name: String = ""              // 예: "Local", "Production" — 자유 편집
    var sortOrder: Int = 0
    var repository: Repository?

    init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
    }
}

@Model
final class Repository {
    var uuid: String = UUID().uuidString   // Keychain 계정 키용 안정 식별자 (persistentID는 기기별로 다름)
    var name: String = ""
    var gitRemoteURL: String? = nil        // 예: git@github.com:me/blog.git
    var defaultBranch: String? = nil       // 예: main
    var localPathBookmark: Data? = nil     // 레거시(Phase 3까지) — §3.13부터 UserDefaults "bookmark.{uuid}"에 저장, 읽는 시점에 이전
    var localPathDisplay: String? = nil    // UI 표시용 경로 문자열
    var createdAt: Date = Date()
    var workspace: Workspace?
    @Relationship(deleteRule: .cascade, inverse: \Target.repository)
    var targets: [Target]? = []
    @Relationship(deleteRule: .cascade, inverse: \Credential.repository)
    var credentials: [Credential]? = []
    @Relationship(deleteRule: .cascade, inverse: \EnvEnvironment.repository)
    var environments: [EnvEnvironment]? = []

    init(name: String) {
        self.name = name
    }
}

extension Repository {
    /// 정렬된 환경 이름 목록 — 화면 전반의 공통 소비 형태.
    var environmentNames: [String] {
        (environments ?? []).sorted { $0.sortOrder < $1.sortOrder }.map(\.name)
    }

    /// 로컬 env 파일에 영향을 주는 SwiftData/CloudKit 변경만 관찰한다.
    var envContentRevision: Int {
        var hash = Hasher()
        hash.combine(uuid)
        for target in (targets ?? []).sorted(by: { $0.envFilePath < $1.envFilePath }) {
            hash.combine(target.relativePath)
            hash.combine(target.outputPath)
            for variable in (target.variables ?? []).sorted(by: {
                ($0.environmentName, $0.key) < ($1.environmentName, $1.key)
            }) {
                hash.combine(variable.environmentName)
                hash.combine(variable.key)
                hash.combine(variable.value)
                hash.combine(variable.isSecret)
                hash.combine(variable.isIgnored)
                hash.combine(variable.updatedAt)
            }
        }
        return hash.finalize()
    }
}

/// 프로젝트 스코프 계정 (§확장) — 스테이징 테스트 계정, 관리자 콘솔 로그인 등.
/// 비밀번호는 Variable의 Secret과 동일하게 Keychain에만 저장 (계정 키: "envide.cred.{uuid}").
@Model
final class Credential {
    var uuid: String = UUID().uuidString   // Keychain 계정 키용 안정 식별자
    var label: String = ""                 // 예: "Staging 관리자"
    var username: String = ""
    var urlString: String? = nil           // 웹 주소(https://…) 또는 앱 스키마(myapp://…)
    var note: String? = nil
    var updatedAt: Date = Date()
    var repository: Repository?

    init(label: String, username: String = "") {
        self.label = label
        self.username = username
    }
}

@Model
final class Target {
    var relativePath: String = "."             // 루트 Target은 "." / 모노레포는 "apps/shop"
    var examplePath: String = ".env.example"   // Target 기준 상대 경로
    var outputPath: String = ".env.local"      // 실제 env 파일명 (발견 시 즉시 실제 이름으로 설정)
    var exampleSnapshot: String? = nil         // 마지막으로 확인한 example 내용 (diff 기준점)
    var repository: Repository?
    @Relationship(deleteRule: .cascade, inverse: \Variable.target)
    var variables: [Variable]? = []

    init(relativePath: String = ".") {
        self.relativePath = relativePath
    }
}

@Model
final class Variable {
    var key: String = ""
    var value: String = ""             // isSecret == true면 빈 문자열, 실값은 Keychain (§2.2)
    var note: String? = nil
    var isSecret: Bool = false
    var isIgnored: Bool = false        // example diff에서 "무시" 선택한 키
    var environmentName: String = ""   // 신규 데이터는 Target.envFilePath를 scope로 저장
    var updatedAt: Date = Date()
    var target: Target?

    init(key: String, value: String = "", environmentName: String) {
        self.key = key
        self.value = value
        self.environmentName = environmentName
    }
}

@Model
final class HistoryEntry {
    var timestamp: Date = Date()
    var action: String = ""            // "created" | "updated" | "renamed" | "deleted"
    var key: String = ""
    var environmentName: String = ""
    var repositoryName: String = ""
    var targetPath: String = ""
    var oldValueHash: String? = nil    // SHA256 앞 8자 — 값 자체는 저장하지 않음
    var source: String = "manual"      // "manual" | "fileImport" | "bundleImport" | "exampleSync" | "localSync" | "credential"
    var batchId: UUID? = nil           // 같은 행동(import/sync)으로 묶인 변경 — UI에서 그룹 표시

    init(action: String, key: String, environmentName: String, repositoryName: String, targetPath: String,
         oldValueHash: String? = nil, source: String = "manual", batchId: UUID? = nil) {
        self.action = action
        self.key = key
        self.environmentName = environmentName
        self.repositoryName = repositoryName
        self.targetPath = targetPath
        self.oldValueHash = oldValueHash
        self.source = source
        self.batchId = batchId
    }
}

extension Target {
    /// Repository 루트 기준 실제 env 파일 경로. 논리 Environment 대신 이 경로가 변수 scope다.
    var envFilePath: String {
        relativePath == "." ? outputPath : "\(relativePath)/\(outputPath)"
    }

    /// Settings의 기본 경로 패턴을 적용해 생성 (§4.5).
    static func makeWithDefaults(relativePath: String) -> Target {
        let target = Target(relativePath: relativePath)
        target.examplePath = UserDefaults.standard.string(forKey: "defaultExamplePath") ?? ".env.example"
        target.outputPath = UserDefaults.standard.string(forKey: "defaultOutputPath") ?? ".env.local"
        return target
    }
}

extension Workspace {
    static let allModels: [any PersistentModel.Type] =
        [Workspace.self, EnvEnvironment.self, Repository.self, Target.self, Variable.self,
         Credential.self, HistoryEntry.self]

}
