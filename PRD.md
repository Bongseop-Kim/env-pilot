# Env IDE — PRD

> **Environment Variables deserve an IDE.**

macOS 전용, 개인 개발자를 위한 Environment IDE. AI 주도 개발용 스펙 문서 — 이 문서만으로 구현이 가능하도록 데이터 모델, 동작, 수용 기준을 명시한다.

---

## 1. 개요

### 1.1 비전

Env IDE는 Secret Manager가 아니다. 개인 개발자가 프로젝트의 Environment를 설계하고 관리하는 **IDE**다. Git을 이해하고, Monorepo를 이해하며, `.env.example` 변경을 추적하고, 필요한 `.env`를 생성한다.

### 1.2 해결하는 문제

- 집 ↔ 회사 Mac 간 `.env` 복사 (AirDrop, 메신저, 최신 버전 혼란)
- 프로젝트/Monorepo Target마다 `.env` 수동 생성·관리
- `.env.example` 변경 후 누락 Key 수동 대조
- `.env`가 Git에 커밋되는 사고

### 1.3 타겟 유저

React / React Native / Next.js / Node.js / FastAPI / NestJS를 쓰는 **개인 개발자**. 특히 여러 Mac 사용, 사이드 프로젝트 다수 운영, Monorepo 사용자.

### 1.4 포지셔닝

| 서비스 | 목적 |
|---|---|
| 1Password / Bitwarden | 비밀번호 저장 |
| Infisical | 팀 Secret 관리 |
| Doppler | CI/CD Secret |
| **Env IDE** | **개인 개발자의 Environment 관리** |

### 1.5 Non-goals

- 자체 백엔드/서버 없음 (FastAPI, Supabase 미사용 — Sync는 iCloud + 파일 공유로 해결)
- 팀 협업, 실시간 공동 편집
- AI 코드 분석, AST 파싱
- VSCode Extension, CLI
- CI/CD 연동, 외부 Secret Manager 연동

---

## 2. 도메인 모델

### 2.1 계층 구조

```
Workspace
└── Environment (Local / Development / Staging / Production …)
└── Repository (Git 저장소)
    └── Target (모노레포 하위 패키지, 예: apps/shop)
        └── EnvBinding (examplePath ↔ outputPath)
        └── Variable (Environment별 key=value)
```

- **Environment는 Workspace 수준의 전역 개념.** 상단 셀렉터에서 선택하면 앱 전체가 해당 Environment 기준으로 표시된다.
- **실제 데이터 저장은 Repository → Target → Environment → Variable** 경로로 귀속된다.

### 2.2 SwiftData 엔티티

CloudKit 동기화를 전제로 하므로 **모든 프로퍼티는 optional 또는 기본값 필수, `@Attribute(.unique)` 사용 불가** — 유니크 제약은 애플리케이션 레벨에서 강제한다.

```swift
@Model final class Workspace {
    var name: String = "Default"
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade) var environments: [EnvEnvironment]? = []
    @Relationship(deleteRule: .cascade) var repositories: [Repository]? = []
}

@Model final class EnvEnvironment {   // 'Environment'는 SwiftUI와 충돌하므로 접두어 사용
    var name: String = ""             // "Local", "Development", "Staging", "Production"
    var sortOrder: Int = 0
    var workspace: Workspace?
}

@Model final class Repository {
    var name: String = ""
    var gitRemoteURL: String? = nil        // 예: git@github.com:me/blog.git
    var defaultBranch: String? = nil       // 예: main
    var localPathBookmark: Data? = nil     // 보안 스코프 북마크 — 기기별 값, CloudKit 동기화 제외 필드로 취급
    var localPathDisplay: String? = nil    // UI 표시용 경로 문자열 (동기화됨)
    var createdAt: Date = Date()
    var workspace: Workspace?
    @Relationship(deleteRule: .cascade) var targets: [Target]? = []
}

@Model final class Target {
    var relativePath: String = ""          // 루트 Target은 "." / 모노레포는 "apps/shop"
    var examplePath: String = ".env.example"   // Target 기준 상대 경로
    var outputPath: String = ".env.local"      // Target 기준 상대 경로
    var exampleSnapshot: String? = nil     // 마지막으로 확인한 example 파일 내용 (diff 기준점)
    var repository: Repository?
    @Relationship(deleteRule: .cascade) var variables: [Variable]? = []
}

@Model final class Variable {
    var key: String = ""
    var value: String = ""                 // isSecret == true면 빈 문자열, 실값은 Keychain
    var note: String? = nil                // 설명
    var isSecret: Bool = false
    var isIgnored: Bool = false            // example diff에서 "무시" 선택한 키
    var environmentName: String = ""       // EnvEnvironment.name 참조 (문자열 — 관계 대신 단순 참조)
    var updatedAt: Date = Date()
    var target: Target?
}

@Model final class HistoryEntry {
    var timestamp: Date = Date()
    var action: String = ""                // "created" | "updated" | "deleted"
    var key: String = ""
    var environmentName: String = ""
    var repositoryName: String = ""
    var targetPath: String = ""
    var oldValueHash: String? = nil        // SHA256 앞 8자 — 값 자체는 저장하지 않음
}
```

**애플리케이션 레벨 유니크 제약:**
- `Variable`: (target, environmentName, key) 조합 유일. 저장 전 중복 검사, 위반 시 저장 거부 + UI 에러.
- `EnvEnvironment`: workspace 내 name 유일.
- `Target`: repository 내 relativePath 유일.

**Secret 저장:**
- `isSecret == true`인 Variable의 실값은 Keychain에 저장. Keychain 계정 키: `"envide.{repository.persistentID}.{target.relativePath}.{environmentName}.{key}"`.
- Keychain 아이템은 `kSecAttrSynchronizable = true`로 저장해 iCloud Keychain으로 동기화한다.
- SwiftData의 `value`는 빈 문자열 유지 (CloudKit에 평문 Secret이 올라가지 않도록).

---

## 3. 기능 스펙

각 기능은 **동작 / 수용 기준 / 엣지 케이스** 순으로 기술한다.

---

### Phase 1 — Core

#### 3.1 Repository 등록

**동작:**
1. `NSOpenPanel`로 폴더 선택.
2. 선택 폴더에서 `git rev-parse --is-inside-work-tree` 실행 — Git 저장소가 아니면 경고 후 등록은 허용.
3. `git remote get-url origin` → `gitRemoteURL`, `git branch --show-current` → `defaultBranch` 자동 채움.
4. 폴더의 보안 스코프 북마크 생성 → `localPathBookmark` 저장.
5. Repository name 기본값은 폴더명, 수정 가능.
6. 루트 Target(`relativePath = "."`) 자동 생성.

**수용 기준:**
- [ ] Git 저장소 폴더 선택 시 remote/branch가 자동으로 채워진다.
- [ ] 앱 재시작 후에도 북마크로 폴더에 접근 가능하다.
- [ ] Git 저장소가 아닌 폴더도 등록 가능하다 (Git 기능만 비활성).

**엣지 케이스:**
- remote 미설정 저장소 → `gitRemoteURL = nil`, 정상 등록.
- 북마크 stale (폴더 이동/삭제) → Repository에 "경로 재연결 필요" 상태 표시, 재선택 UI 제공.
- 동일 경로 중복 등록 → 거부.

#### 3.2 Env Parser

`.env` 파일의 파싱/직렬화 모듈. **라운드트립 보존은 목표가 아니다** — 파싱은 key/value 추출, 직렬화는 앱 데이터로부터의 신규 생성이다.

**파싱 규칙:**

| 입력 | 결과 |
|---|---|
| `KEY=value` | key=`KEY`, value=`value` |
| `export KEY=value` | `export ` 접두어 제거 |
| `KEY="va lue"` / `KEY='va lue'` | 양끝 따옴표 제거, 내부 이스케이프(`\"` → `"`, `\n` → 개행)는 double quote만 처리 |
| `KEY=a=b=c` | 첫 `=` 기준 분리 → value=`a=b=c` |
| `KEY=value # comment` | 따옴표 밖 ` #` 이후는 주석으로 제거 |
| `# comment` / 빈 줄 | 무시 |
| `KEY=` | value=`""` (빈 값도 유효한 키) |
| `잘못된 줄` (`=` 없음) | 무시하되 경고 목록에 수집 |

- 키 유효성: `[A-Za-z_][A-Za-z0-9_]*`. 위반 시 경고 목록에 수집.
- 인코딩: UTF-8 고정. BOM 제거.

**직렬화 규칙:**
- 형식: `KEY=value`, 키 알파벳 순 정렬.
- value에 공백, `#`, `"`, 개행이 포함되면 double quote로 감싸고 이스케이프.
- 파일 끝 개행 1개.

**수용 기준:**
- [ ] 위 파싱 규칙 표의 모든 케이스를 커버하는 유닛 테스트 통과.
- [ ] parse → serialize → parse 결과의 key/value 집합이 동일하다.

#### 3.3 Variable CRUD

**동작:**
- Target + Environment 선택 상태에서 키 추가/수정/삭제.
- 키 이름/값/설명 검색 (실시간 필터).
- Secret 토글: 켜면 값이 Keychain으로 이동하고 UI에서 마스킹(`••••`), 클릭 시 일시 표시. 끄면 Keychain에서 SwiftData로 복귀.
- 값 복사 버튼 (Secret 포함 — 클립보드 복사는 허용).
- 모든 변경은 HistoryEntry 기록 (Phase 3에서 UI 노출, 기록 자체는 Phase 1부터).

**수용 기준:**
- [ ] 같은 (Target, Environment)에 중복 키 추가가 거부된다.
- [ ] Secret 값이 SwiftData 저장소 파일에 평문으로 존재하지 않는다.
- [ ] 검색이 key/note 양쪽에 매칭된다.

#### 3.4 Generate

**동작:**
1. Environment 선택 → Generate 실행 (Repository 단위 또는 Target 단위).
2. 각 Target의 Variables(해당 Environment)를 직렬화해 `{target}/{outputPath}`에 기록.
3. 대상 파일이 이미 존재하고 내용이 다르면 덮어쓰기 확인 다이얼로그 (diff 미리보기 포함).
4. Secret 값은 Keychain에서 읽어 실값으로 출력.
5. 생성 직후 Git Safety 검사 실행 (§3.11) — 출력 파일이 gitignore되지 않았으면 경고.

**수용 기준:**
- [ ] 생성된 파일을 파서로 다시 읽으면 앱의 key/value와 일치한다.
- [ ] 기존 파일과 내용이 동일하면 파일을 건드리지 않는다 (mtime 보존).
- [ ] 변수가 0개인 Target은 스킵하고 결과 요약에 표시한다.

---

### Phase 2 — Monorepo & Git

#### 3.5 Monorepo 자동 탐색

**동작:** Repository 등록 시(및 수동 "Scan" 시) 루트에서 감지:

| 파일 | 규칙 |
|---|---|
| `pnpm-workspace.yaml` | `packages:` glob 목록 |
| `package.json` | `workspaces` 배열 (또는 `workspaces.packages`) |
| `nx.json` 존재 | `package.json` workspaces 규칙과 동일하게 처리 |
| `turbo.json` 존재 | workspaces 정의는 위 둘에서 가져옴 (turbo 자체는 신호일 뿐) |

glob(`apps/*` 등)을 해석해 `package.json`이 존재하는 디렉토리만 Target 후보로 나열 → 사용자가 체크박스로 선택 → Target 생성. 각 Target의 examplePath는 해당 디렉토리에 `.env.example`이 있으면 자동 바인딩.

**수용 기준:**
- [ ] pnpm / npm(yarn) workspaces 각각의 샘플 레포에서 Target 후보가 정확히 나열된다.
- [ ] 모노레포가 아니면 루트 Target 하나만 유지된다.
- [ ] 재스캔 시 기존 Target은 유지되고 신규 후보만 추가 제안된다.

**엣지 케이스:** glob이 심볼릭 링크를 가리키면 무시. `node_modules` 하위는 항상 제외.

#### 3.6 .env.example 변경 감지

**동작:**
- 감지 시점: ① 앱 활성화(foreground 전환) 시 ② 수동 Scan ③ FSEvents로 example 파일 감시 (앱 실행 중).
- 각 Target의 `examplePath` 현재 내용을 파싱해 `exampleSnapshot`의 키 집합과 비교.
- diff = 추가된 키(+), 삭제된 키(−). 값 변경은 example 특성상 추적하지 않음 (키 존재만 비교).

**수용 기준:**
- [ ] `git pull` 후 앱으로 전환하면 example에 추가된 키가 Git Changes 탭에 나타난다.
- [ ] 스냅샷이 없는 최초 스캔은 diff를 만들지 않고 스냅샷만 저장한다.

#### 3.7 Example Diff 처리 UI

**동작:** Git Changes 탭에 Target별 diff 목록 표시. 각 키에 대해:
- **추가** → 모든 Environment에 빈 값 Variable 생성 (값 입력 유도 배지 표시)
- **삭제** → 해당 키의 Variable을 전 Environment에서 삭제 (확인 다이얼로그)
- **무시** → `isIgnored = true`, 이후 diff에서 제외

처리 완료된 diff는 `exampleSnapshot` 갱신으로 소멸.

**수용 기준:**
- [ ] 추가/삭제/무시 각각 처리 후 재스캔 시 같은 diff가 다시 나타나지 않는다.
- [ ] 무시한 키는 이후 example에 계속 존재해도 diff에 뜨지 않는다.

---

### Phase 3 — Insight

#### 3.8 Health Check

**판정 규칙 (Target × Environment 단위 → Repository로 집계):**

| 상태 | 조건 |
|---|---|
| 🟢 Healthy | example의 모든 키(무시 키 제외)가 해당 Environment에 값과 함께 존재 |
| 🟡 Warning | 키는 있으나 값이 빈 Variable 존재, 또는 example 키 누락 |
| 🔴 Critical | 특정 Environment에 Variable이 하나도 없음 (example에는 키가 있는데) |

Repository 상태 = 소속 Target×Environment 중 최악 값. 사이드바에 색상 뱃지, Health 탭에 상세(어떤 키가 어느 Environment에서 누락인지) 표시.

**수용 기준:**
- [ ] 누락 키를 클릭하면 해당 Variable 입력 화면으로 이동한다.

#### 3.9 Compare

**동작:** 키 × Environment 매트릭스. 행 = 키, 열 = Environment, 셀 = 값(Secret은 마스킹). 누락 셀은 강조 표시. 셀 직접 편집 가능. Target 단위로 표시.

**수용 기준:**
- [ ] 한 화면에서 4개 Environment의 같은 키 값을 비교할 수 있다.
- [ ] 누락 셀 클릭으로 즉시 값 입력이 가능하다.

#### 3.10 History

**동작:** HistoryEntry를 날짜별 그룹으로 표시 (예: "Today — OPENAI_MODEL 추가"). 필터: Repository, Environment. 값 자체는 표시하지 않음 (해시만 저장되어 있음). 보존 기간: 최근 1000건, 초과분 자동 삭제.

#### 3.11 Git Safety

**동작:** Generate 시 및 Health 탭에서 각 Target의 outputPath에 대해:
1. `git check-ignore <path>` — ignore되지 않으면 🔴 경고 + `.gitignore`에 한 줄 추가 버튼 제공.
2. `git ls-files <path>` — 이미 tracked면 🔴 경고 (untrack 방법 안내 텍스트만, 자동 실행 안 함).
3. 파일 권한이 `0600`이 아니면 🟡 안내 + 수정 버튼.

**수용 기준:**
- [ ] gitignore 누락 상태에서 Generate하면 경고가 뜬다.
- [ ] ".gitignore에 추가" 버튼이 실제로 항목을 추가하고 재검사가 통과한다.

#### 3.12 Import

**동작:** 기존 `.env` 파일 선택 (또는 Target의 outputPath에서 자동 발견) → 파싱 → Target + Environment 지정 → 일괄 등록.

**충돌 정책:** 기존 키와 겹치면 키별로 "파일 값 사용 / 기존 값 유지" 선택 UI (기본: 파일 값 사용). 값이 동일한 키는 조용히 스킵.

**수용 기준:**
- [ ] Repository 등록 직후 기존 `.env.local`을 임포트해 즉시 관리 상태로 만들 수 있다.

---

### Phase 4 — Sync

#### 3.13 iCloud 자동 동기화

**동작:** SwiftData + CloudKit(`ModelConfiguration(cloudKitDatabase: .automatic)`)으로 같은 Apple 계정의 Mac 간 데이터 자동 동기화.

- **동기화 대상:** Workspace, Environment, Repository(메타), Target, Variable(비밀 아닌 값), HistoryEntry.
- **동기화 제외:** `localPathBookmark` — 기기별 값. 다른 Mac에서 처음 열면 Repository가 "경로 미연결" 상태로 나타나고, 로컬 폴더를 지정하면 연결된다 (§3.1 재연결 UI 재사용).
- **Secret:** iCloud Keychain(`kSecAttrSynchronizable`)이 별도 채널로 동기화 — CloudKit에는 올라가지 않음.
- **충돌 정책:** CloudKit 기본 last-write-wins 수용. 커스텀 병합 없음.

**수용 기준:**
- [ ] Mac A에서 추가한 Variable이 Mac B에 나타난다 (Secret 포함).
- [ ] Mac B에서 로컬 경로만 지정하면 Generate까지 동작한다.

#### 3.14 Export / Import 번들 (수동 공유)

**동작:**
- Export: Repository(또는 전체 Workspace) 선택 → 단일 `.envide` 파일(JSON) 생성. Secret 실값 포함 여부 선택 — 포함 시 사용자 입력 패스프레이즈로 CryptoKit(AES-GCM, PBKDF2 키 유도) 암호화.
- 전달은 사용자 몫 (AirDrop, 이메일 등 — 앱은 관여하지 않고 macOS 공유 시트만 제공).
- Import: `.envide` 파일 열기 → (암호화 시 패스프레이즈 입력) → 미리보기 → §3.12와 동일한 충돌 정책으로 병합.

**수용 기준:**
- [ ] 암호화 export 파일은 텍스트 에디터로 열었을 때 Secret이 노출되지 않는다.
- [ ] 잘못된 패스프레이즈는 명확한 에러로 실패한다 (부분 임포트 없음).
- [ ] export → 다른 Mac에서 import → Generate 결과가 원본과 동일하다.

---

## 4. UI 스펙

### 4.1 레이아웃

```
┌────────────────────────────────────────────────────┐
│ 툴바:                    [Environment ▾]  [Generate]│
├──────────┬─────────────────────────────────────────┤
│ Sidebar  │ Repository 상세                          │
│          │ ┌─ Target 트리 (apps/shop, services/api)│
│ Reposito-│ ├─ 탭: Variables│Compare│Health│Git     │
│ ries     │ │        Changes                        │
│ History  │ │                                       │
│ Settings │ │  (선택 탭 콘텐츠)                       │
└──────────┴─────────────────────────────────────────┘
```

- `NavigationSplitView` 3-column: 사이드바 / Target 목록 / 콘텐츠.
- 사이드바 Repository 항목에 Health 뱃지(🟢🟡🔴)와 미처리 diff 개수 뱃지.

### 4.2 전역 Environment 셀렉터

- 툴바 우측 상단 드롭다운. 선택 시 Variables/Health/Generate가 모두 해당 Environment 기준으로 즉시 갱신.
- Compare 탭만 예외 (전 Environment 동시 표시).
- 선택값은 앱 전역 상태로 유지, 재시작 시 복원.

### 4.3 화면별 상태

| 화면 | 빈 상태 | 에러 상태 |
|---|---|---|
| Repository 목록 | "폴더를 드래그하거나 + 로 추가" | — |
| Variables | "키가 없습니다 — example에서 가져오기 / 직접 추가" | 경로 미연결 시 재연결 CTA |
| Git Changes | "변경 없음 ✓" | git 실행 실패 시 원인 메시지 |
| Health | 전부 🟢일 때 "All Healthy" | — |

### 4.4 메뉴바 앱 (`MenuBarExtra`)

- Environment 전환 서브메뉴
- Repository별 Health 요약 (아이콘 + 이름)
- Generate (현재 Environment 기준, Repository 선택 서브메뉴)
- Scan Now
- 메인 창 열기

### 4.5 Settings

- Workspace 이름, Environment 목록 편집(추가/삭제/순서)
- iCloud Sync on/off
- 기본 examplePath / outputPath 패턴

---

## 5. 기술 아키텍처

| 영역 | 선택 | 비고 |
|---|---|---|
| 플랫폼 | macOS 14+ | SwiftData + MenuBarExtra 요구 |
| UI | SwiftUI | AppKit 브릿지는 NSOpenPanel 등 최소한만 |
| 저장 | SwiftData (+CloudKit, Phase 4) | §2.2 제약 준수 |
| Secret | Keychain (`kSecAttrSynchronizable`) | iCloud Keychain 동기화 |
| 암호화 | CryptoKit (AES-GCM) | Export 번들 전용 |
| Git | `git` CLI를 `Process`로 실행 | 라이브러리 미사용. 필요 명령: `rev-parse`, `remote get-url`, `branch --show-current`, `check-ignore`, `ls-files` |
| 파일 감시 | FSEvents (`DispatchSource` 또는 `FSEventStream`) | example 파일 한정 |
| 샌드박스 | App Sandbox + 보안 스코프 북마크 | 폴더 접근 전 `startAccessingSecurityScopedResource` |

**프로젝트 구조 (제안):**

```
EnvIDE/
├── Models/          # SwiftData 엔티티 (§2.2)
├── Services/
│   ├── EnvParser.swift       # §3.2 — 순수 함수, 유닛 테스트 대상
│   ├── GitService.swift      # git CLI 래퍼
│   ├── MonorepoScanner.swift # §3.5
│   ├── SecretStore.swift     # Keychain 래퍼
│   ├── GenerateService.swift
│   └── BundleCodec.swift     # §3.14 export/import
├── Views/
└── MenuBar/
```

---

## 6. 마일스톤

| Phase | 범위 | Definition of Done |
|---|---|---|
| 1 | Repository 등록, Parser, Variable CRUD, Generate | 실제 프로젝트 하나를 등록해 `.env.local`을 생성하고 앱이 그 파일의 유일한 소스가 된다 |
| 2 | Monorepo 탐색, example diff 감지/처리 | 실제 모노레포에서 `git pull` 후 새 키를 앱 안에서 처리할 수 있다 |
| 3 | Health, Compare, History, Import, Git Safety | 사이드바만 봐도 모든 프로젝트의 env 상태를 파악할 수 있다 |
| 4 | iCloud Sync, Export/Import 번들 | 두 번째 Mac에서 로컬 경로 지정만으로 동일한 Generate 결과를 얻는다 |
