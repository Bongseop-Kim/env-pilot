# Env Pilot 1.1

- Health 탭에 보안 검사 통합 — secret 노출, Git 히스토리에 커밋된 `.env` 감지
- FSEvents 기반 저장소 감시로 `.env` 변경 실시간 반영
- 변경 이력을 출처(import/sync)별로 묶어 요약 표시
- 변수·자격증명 편집 지원 (비밀번호 등 secret은 보존)
- Seed 디자인 시스템 전면 도입으로 일관된 UI와 타이포그래피
- Environment를 Repository 단위로 범위화 (기존 데이터 자동 마이그레이션)
