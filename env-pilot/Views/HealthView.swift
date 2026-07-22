import SwiftUI

extension HealthStatus {
    var color: Color {
        switch self {
        case .healthy: SeedColor.fgPositive
        case .warning: SeedColor.fgWarning
        case .critical: SeedColor.fgCritical
        }
    }
}

/// Health 탭 (PRD §3.8) — 실제 env 파일이 example 키를 충족하는지 판정하고,
/// secret 노출 방지(Git Safety·히스토리·hook·AI)를 SecuritySections로 함께 보여준다.
struct HealthView: View {
    let items: [HealthService.Item]
    let onSelectMissingKey: (_ filePath: String, _ key: String) -> Void
    let security: SecuritySections

    var body: some View {
        List {
            envSection
            security
        }
    }

    @ViewBuilder private var envSection: some View {
        Section("환경변수") {
            if items.isEmpty {
                Label("판정 대상 없음 — .env.example과 함께 확인할 실제 env 파일이 없습니다",
                      systemImage: "questionmark.circle")
                    .foregroundStyle(SeedColor.fgNeutralMuted)
                    .seedListRow()
            } else if items.allSatisfy({ $0.status == .healthy }) {
                Label("All Healthy — 모든 .env 파일이 example 키를 충족합니다",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(SeedColor.fgPositive)
                    .seedListRow()
            } else {
                healthSections
            }
        }
    }

    /// SecuritySections의 행과 같은 구조 — 파일 경로 위, 상세(키 칩) 아래.
    @ViewBuilder private var healthSections: some View {
        ForEach(items) { item in
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(item.filePath).fontDesign(.monospaced)
                } icon: {
                    Image(systemName: item.status.iconName)
                        .foregroundStyle(item.status.color)
                }
                keyChips(item)
            }
            .seedListRow()
        }
    }

    @ViewBuilder private func keyChips(_ item: HealthService.Item) -> some View {
        if item.status == .healthy {
            Text("Healthy").foregroundStyle(SeedColor.fgNeutralMuted).font(SeedTypography.body)
        } else {
            // 누락 키 클릭 → 해당 Variable 입력으로 이동 (§3.8 수용 기준)
            FlowLayout(spacing: SeedSpacing.x1) {
                ForEach(item.missingKeys, id: \.self) { key in
                    Button("\(key) 누락") {
                        onSelectMissingKey(item.filePath, key)
                    }
                    .buttonStyle(.seedChip(.critical))
                }
                ForEach(item.emptyValueKeys, id: \.self) { key in
                    Button("\(key) 빈 값") {
                        onSelectMissingKey(item.filePath, key)
                    }
                    .buttonStyle(.seedChip(.warning))
                }
            }
        }
    }
}
