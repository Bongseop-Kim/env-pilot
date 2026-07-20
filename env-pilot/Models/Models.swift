import Foundation
import SwiftData

// PRD §2.2 — SwiftData 엔티티.
// CloudKit 동기화 전제: 모든 프로퍼티는 optional 또는 기본값, @Attribute(.unique) 사용 불가,
// 관계는 optional. 유니크 제약(§2.2)은 저장 전 애플리케이션 레벨에서 검사한다.

@Model
final class Workspace {
    var name: String = "Default"
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \EnvEnvironment.workspace)
    var environments: [EnvEnvironment]? = []
    @Relationship(deleteRule: .cascade, inverse: \Repository.workspace)
    var repositories: [Repository]? = []

    init(name: String = "Default") {
        self.name = name
    }
}

/// 'Environment'는 SwiftUI와 충돌하므로 접두어 사용.
@Model
final class EnvEnvironment {
    var name: String = ""              // "Local", "Development", "Staging", "Production"
    var sortOrder: Int = 0
    var workspace: Workspace?

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
    var localPathBookmark: Data? = nil     // 보안 스코프 북마크 — 기기별 값 (다른 Mac에서는 재연결 필요)
    var localPathDisplay: String? = nil    // UI 표시용 경로 문자열
    var createdAt: Date = Date()
    var workspace: Workspace?
    @Relationship(deleteRule: .cascade, inverse: \Target.repository)
    var targets: [Target]? = []

    init(name: String) {
        self.name = name
    }
}

@Model
final class Target {
    var relativePath: String = "."             // 루트 Target은 "." / 모노레포는 "apps/shop"
    var examplePath: String = ".env.example"   // Target 기준 상대 경로
    var outputPath: String = ".env.local"      // Target 기준 상대 경로
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
    var environmentName: String = ""   // EnvEnvironment.name 문자열 참조
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
    var action: String = ""            // "created" | "updated" | "deleted"
    var key: String = ""
    var environmentName: String = ""
    var repositoryName: String = ""
    var targetPath: String = ""
    var oldValueHash: String? = nil    // SHA256 앞 8자 — 값 자체는 저장하지 않음

    init(action: String, key: String, environmentName: String, repositoryName: String, targetPath: String, oldValueHash: String? = nil) {
        self.action = action
        self.key = key
        self.environmentName = environmentName
        self.repositoryName = repositoryName
        self.targetPath = targetPath
        self.oldValueHash = oldValueHash
    }
}

extension Workspace {
    static let allModels: [any PersistentModel.Type] =
        [Workspace.self, EnvEnvironment.self, Repository.self, Target.self, Variable.self, HistoryEntry.self]

    static let defaultEnvironmentNames = ["Local", "Development", "Staging", "Production"]
}
