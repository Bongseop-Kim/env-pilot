# Env Pilot — PRD

> **Environment Variables deserve an IDE.**

macOS 전용 개인 개발자용 `.env` 관리 앱이다. 논리적인 Environment를 앱 안에서 새로 구성하지 않고, 프로젝트에 실제로 존재하는 env 파일과 그 경로를 그대로 관리한다.

---

## 1. 제품 원칙

### 1.1 실제 파일이 기준이다

- `.env`, `.env.local`, `.env.production`, `apps/api/.env`처럼 프로젝트에 존재하는 파일 하나가 하나의 관리 단위다.
- `Local`, `Development`, `Production` 같은 논리 Environment 선택기는 제공하지 않는다.
- 사용자가 Target이나 출력 경로를 미리 설정하지 않는다.
- 앱은 `.env.local`을 기본값으로 가정하거나 빈 파일을 임의로 만들지 않는다.
- 동일 폴더에 여러 env 파일이 있으면 각각 독립적으로 관리한다.

### 1.2 자동화는 비파괴적이어야 한다

- 최초 연결에서는 실제 파일의 키와 값을 우선하여 가져온다.
- 한쪽만 변경된 경우 안전하게 자동 반영한다.
- 파일 삭제, 양쪽 동시 변경, 파싱 실패는 자동 덮어쓰기하지 않고 사용자가 방향을 선택한다.
- diff가 없으면 동기화 버튼이나 불필요한 상태 메시지를 보여주지 않는다.

### 1.3 Non-goals

- 앱 내부의 Environment 설계 및 전환
- 앱이 정한 출력 경로로 env 파일 자동 생성
- 팀용 Secret Manager, 자체 서버, 실시간 공동 편집
- CI/CD 및 외부 Secret Manager 연동

---

## 2. 도메인 모델

### 2.1 사용자 관점

```text
Workspace
└── Repository
    ├── .env
    │   └── Variable (key=value)
    ├── .env.local
    │   └── Variable (key=value)
    └── apps/api/.env.production
        └── Variable (key=value)
```

변수를 식별하는 기준은 `(Repository, 실제 env 파일 경로, key)`다.

### 2.2 구현 모델

기존 SwiftData 스키마와 저장 데이터의 호환성을 위해 클래스 이름 `Target`과 필드 `environmentName`은 유지한다. 사용자에게는 노출하지 않는다.

- `Target` 하나는 실제 env 파일 하나를 뜻한다.
- `Target.relativePath + Target.outputPath`가 Repository 기준 실제 파일 경로다.
- `Target.envFilePath`가 화면, 동기화 체크포인트, Variable scope의 공통 식별자다.
- `Variable.environmentName`에는 논리 Environment가 아니라 `Target.envFilePath`를 저장한다.
- 기존 `EnvEnvironment` 데이터는 마이그레이션 및 구버전 번들 호환 목적으로만 남고 신규 UI와 동기화에서는 사용하지 않는다.

```swift
@Model final class Repository {
    var uuid: String
    var name: String
    var localPathDisplay: String?
    var targets: [Target]?
}

@Model final class Target {
    var relativePath: String       // "." 또는 "apps/api"
    var outputPath: String         // ".env", ".env.local", ".env.production"
    var examplePath: String        // 같은 폴더의 ".env.example"
    var variables: [Variable]?

    var envFilePath: String        // 예: "apps/api/.env.production"
}

@Model final class Variable {
    var key: String
    var value: String
    var isSecret: Bool
    var environmentName: String    // 내부 호환 필드: envFilePath 저장
    var target: Target?
}
```

### 2.3 Secret 저장

- Secret 실값은 SwiftData나 CloudKit에 저장하지 않고 Keychain에 저장한다.
- Keychain 항목은 Repository UUID, 실제 파일 scope, key를 조합해 구분한다.
- `kSecAttrSynchronizable = true`를 사용해 iCloud Keychain으로 동기화한다.
- Secret 표시 및 복사 시 사용자 인증을 요구할 수 있다.

---

## 3. 핵심 기능

### 3.1 Repository 등록

1. 사용자가 프로젝트 폴더를 선택한다.
2. 보안 스코프 북마크와 표시 경로를 저장한다.
3. Git remote와 branch를 읽을 수 있으면 함께 저장한다.
4. 실제 env 파일을 즉시 탐색하고 내용을 가져온다.
5. env 파일이 없으면 관리 항목을 만들지 않는다.

경로가 이동하거나 권한이 만료되면 `폴더 다시 연결…`만 제공한다.

### 3.2 env 파일 탐색

관리 대상:

- `.env`
- `.env.*` 형태의 실제 값 파일

제외 대상:

- `.env.example`, `.env.sample`, `.env.template`, `.env.dist`, `.env.schema`
- `.git`, `node_modules`, `.build`, `.next`, `.venv`, `DerivedData`, `Pods`, `build`, `dist` 하위
- 심볼릭 링크 디렉터리 하위

탐색은 Repository 전체에서 재귀적으로 수행한다. 사용자는 Repository 메뉴의 `.env 파일 다시 찾기`로 수동 재탐색할 수 있으며 앱 활성화와 파일 감시를 통해서도 갱신된다.

### 3.3 Parser

- `KEY=value`와 `export KEY=value`를 지원한다.
- 첫 번째 `=`를 기준으로 key/value를 구분한다.
- 따옴표, 공백, `#` 주석, 개행 이스케이프를 처리한다.
- 키는 `[A-Za-z_][A-Za-z0-9_]*` 형식이어야 한다.
- UTF-8만 지원하고 잘못된 줄은 경고로 수집한다.
- 직렬화 시 키를 정렬하고 파일 끝 개행을 하나 유지한다.

### 3.4 최초 가져오기

- 발견한 파일마다 실제 키와 값을 그대로 읽는다.
- 기존 앱 데이터가 없거나 구버전 Environment 데이터만 있으면 실제 파일을 우선한다.
- 새로 가져온 값은 기본적으로 Secret으로 저장한다.
- `.env`가 있는데 `.env.local` Target만 남아 있는 구버전 데이터는 실제 `.env` 경로로 전환한다.
- `.env.local`을 새로 만들거나 실제 값을 빈 문자열로 치환하지 않는다.

### 3.5 자동 동기화

각 실제 파일별로 마지막 합의 내용의 정규화 SHA256을 기기 로컬 `UserDefaults`에 저장한다.

| 상태 | 처리 |
|---|---|
| 파일과 Env Pilot 값이 같음 | 아무 작업도 하지 않음 |
| Env Pilot만 변경 | 해당 실제 파일에 atomic write |
| 파일만 추가·수정 | Env Pilot로 자동 가져오기 |
| 양쪽이 모두 변경 | `Changes`에 diff 표시 |
| 파일에서 키 또는 파일 자체 삭제 | 자동 삭제하지 않고 `Changes`에 표시 |
| 파싱 실패 | 원인을 표시하고 자동 쓰기 중단 |
| Keychain 값 미도착 | 빈 값으로 쓰지 않고 대기 |

동일한 내용이면 파일을 다시 쓰지 않는다. 한 파일의 변경이 다른 env 파일에 영향을 주면 안 된다.

### 3.6 diff와 동기화 액션

- 동기화 버튼은 `Variables` 탭에서 선택한 파일에 실제 drift가 있을 때만 표시한다.
- 버튼은 `동기화…`로 표시하며 `Changes` 탭으로 이동한다.
- `Accounts`, `Health`, `Changes` 공통 헤더에는 동기화 버튼을 두지 않는다.
- `Changes`에서는 다음 중 하나를 선택한다.
  - `로컬 변경 검토`: 키별로 파일 값 사용 여부와 삭제 반영 여부 선택
  - `Env Pilot 값 적용`: 앱 값을 실제 파일에 적용
  - `파일 복원`: 삭제된 파일을 앱 값으로 복원
- 자동으로 선택할 수 없는 방향을 단일 버튼으로 즉시 실행하지 않는다.

### 3.7 Variable 편집

- 선택한 실제 env 파일의 키만 표시한다.
- 상단 툴바의 `+` 버튼 하나로 키를 추가한다.
- 콘텐츠 안에 중복 `키 추가` 버튼을 만들지 않는다.
- 값과 설명을 인라인 편집하고, Secret은 마스킹·인증 후 표시한다.
- 키 또는 설명을 검색할 수 있다.
- dotenv, shell exports, JSON 형식으로 복사할 수 있다.

### 3.8 `.env.example`

- 실제 env 파일과 같은 폴더의 `.env.example` 키를 비교한다.
- 추가·삭제된 키를 `Changes`에서 파일별로 처리한다.
- 추가 시 해당 실제 파일에만 빈 키를 만들고, 삭제 시 해당 파일의 키만 대상으로 한다.
- Variables에서 선택 파일의 키로 `.env.example`을 역생성할 수 있다.

### 3.9 Health

Health는 실제 env 파일 단위로 판정한다.

| 상태 | 조건 |
|---|---|
| Healthy | example의 모든 키가 값과 함께 존재 |
| Warning | 키가 누락되었거나 값이 비어 있음 |
| Critical | example에는 키가 있지만 해당 실제 파일의 Variable이 없음 |

누락 키를 누르면 해당 실제 파일을 선택하고 기존 상단 `+` 입력 흐름으로 이동한다.

### 3.10 Git Safety

- 실제 env 파일이 `.gitignore` 대상인지 확인한다.
- Git index에 tracked 상태인지 확인한다.
- 파일 권한이 `0600`인지 확인한다.
- 안전하지 않으면 자동 쓰기를 중단하고 Health에서 해결 방법을 제공한다.
- 선택적으로 pre-commit hook을 설치해 `.env`와 `.env.*` 커밋을 차단한다. example 파일은 제외한다.

### 3.11 History, Accounts, 백업

- History는 Repository와 실제 파일 경로로 필터링한다.
- Accounts는 Repository 단위이며 env 파일 동기화와 무관하다.
- `.envide` 번들은 Repository, 실제 파일 경로, Variable을 보존한다.
- Secret 포함 번들은 패스프레이즈 기반 AES-GCM으로 암호화한다.

### 3.12 iCloud

- Repository 메타데이터, 실제 파일 binding, Variable, History는 SwiftData + CloudKit으로 동기화한다.
- 로컬 폴더 북마크와 파일 체크포인트는 기기별 값이므로 CloudKit에 저장하지 않는다.
- 다른 Mac에서는 Repository 폴더를 다시 연결하면 그 Mac의 실제 파일과 비교한다.
- 파일과 Cloud 값이 모두 존재하고 다르면 임의 덮어쓰기하지 않고 diff로 처리한다.

---

## 4. UI 스펙

```text
┌──────────────┬──────────────────────────────────────────┐
│ Repositories │ Variables 탭: [apps/api/.env.production] │
│              ├──────────────────────────────────────────┤
│ History      │ Variables | Accounts | Health | Changes │
│              ├──────────────────────────────────────────┤
│              │ drift가 있을 때만 [동기화…]             │
│              │ 실제 파일의 key/value 목록               │
└──────────────┴──────────────────────────────────────────┘
```

### 4.1 파일 선택

- 실제 env 파일이 하나면 경로를 정적인 문맥 라벨로 표시한다.
- 여러 개면 실제 Repository 상대 경로 목록에서 선택한다.
- 파일 선택 UI는 `Variables` 탭에서만 표시한다.
- Environment 편집, 로컬 피커, Target 피커는 제공하지 않는다.

### 4.2 상태 표시

- 정상 상태에서는 `동기화됨`, `동기화 전` 같은 상시 상태를 표시하지 않는다.
- 실제 drift가 있으면 정확한 원인과 `동기화…` 버튼을 표시한다.
- 파일 접근·Git Safety·파싱 문제는 원인과 이동 가능한 해결 액션을 표시한다.
- 빈 Repository에는 `.env 파일을 찾지 못했습니다`와 `다시 찾기`만 표시한다.
- 상태 설명을 위해 의미 없는 정보 아이콘이나 임의의 경로 문장을 추가하지 않는다.

### 4.3 Settings

- Workspace 이름
- 로그인 시 시작
- Secret 표시·복사 인증
- iCloud 동기화

Environment 목록과 기본 output 경로 설정은 제공하지 않는다.

---

## 5. 수용 기준

- [ ] 프로젝트 루트에 `.env`만 있으면 `.env`의 키와 실제 값이 즉시 표시된다.
- [ ] `.env`가 있는데 `.env.local`로 잘못 연결되거나 `.env.local`이 생성되지 않는다.
- [ ] `.env`, `.env.local`, 중첩 `.env.production`이 각각 독립된 경로로 표시된다.
- [ ] `.env.example`과 `node_modules` 하위 env 파일은 값 파일 목록에서 제외된다.
- [ ] Environment 선택기와 편집 UI가 어디에도 나타나지 않는다.
- [ ] 키 추가 액션은 Variables 툴바의 `+` 하나만 제공된다.
- [ ] 실제 diff가 없으면 동기화 버튼이 나타나지 않는다.
- [ ] 실제 diff가 있으면 선택 파일의 Variables 영역에만 동기화 버튼이 나타난다.
- [ ] Accounts, Health, Changes 탭에서는 공통 동기화 버튼이 나타나지 않는다.
- [ ] 로컬과 앱이 동시에 바뀌면 어느 쪽도 자동 덮어쓰지 않는다.
- [ ] 파일 삭제는 자동 데이터 삭제로 이어지지 않으며 복원할 수 있다.
- [ ] 한 파일의 값을 변경해도 다른 env 파일 내용은 바뀌지 않는다.

---

## 6. 기술 아키텍처

| 영역 | 선택 |
|---|---|
| 플랫폼/UI | macOS, SwiftUI |
| 모델 | SwiftData + CloudKit |
| Secret | Keychain (`kSecAttrSynchronizable`) |
| 파싱 | `EnvParser` |
| 파일 발견·동기화 | `LocalSyncService` |
| 파일 감시 | `DispatchSourceFileSystemObject` |
| Git 안전성 | `.gitignore`, index, 권한 검사 |
| 샌드박스 | 보안 스코프 북마크 |

핵심 테스트는 실제 경로 탐색, 최초 값 가져오기, 파일별 독립성, 양쪽 변경 conflict, 삭제 복원, watcher를 검증한다.
