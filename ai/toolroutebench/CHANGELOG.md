# ToolRouteBench 변경 기록

## Unreleased

- development 360건과 봉인 Holdout 192건을 생성·검증·동결했다.
- group-aware 5-fold OOF로 `embedding-09`를 잠그고 Holdout을 한 번 실행했다.
- Embedding 후보가 분류 품질은 높였지만 NORMAL 오활성률을 개선하지 못해
  제품 미통합을 결정하고 MVP 안전성 개선을 P0로 승격했다.
- Pilot 핵심 결과·해시·미검증 범위를 `RESULTS.md`에 추가했다.
- 615-record authoring plan과 Codex CLI 생성기를 추가했다.
- 정답 라벨을 숨기는 계약·블라인드 독립 검증 단계를 추가했다.
- registry SHA 검증, CPU EmbeddingGemma 추출과 resumable checkpoint를 추가했다.
- 33개 호환 후보 Dev grid, Regex 안전 gate와 Holdout lock runner를 추가했다.
- Swift Regex Router의 SHA 고정 Python 포트와 기준선 exporter를 추가했다.

## 0.1.0 — 2026-08-08

- Embedding-only multi-label Tool Router Pilot 계약 추가
- 7개 Tool과 615개 데이터 계획 고정
- Regex baseline 안전 gate와 Holdout 1회 정책 고정
- 계약 검증·벡터 집계·채점·후보 선택 하니스 골격 추가
