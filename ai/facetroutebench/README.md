status:: active

# FacetRouteBench

Gemma 생성형 Scene Router와 EmbeddingGemma 유사도 Router의 20개 라우트 분류 품질 및 Router 단독 지연시간을 비교하기 위한 연구 하니스다.

현재 단계는 **v2 threshold 구조 비교 종료, v3 GENERAL Authoring 계약·러너 구축, v3 데이터 미생성, 새 Frozen 실험 미실행**이다. v2 회고 실험은 5-fold 교차검증으로 정규화한 라우트별 threshold를 다음 확인 후보로 선택했다. v3는 독립 GENERAL prototype 240개와 전문-vs-GENERAL Top-1 직접 경쟁 후보도 유지해 새 Dev에서 비교한다. 모델 가중치와 생성 산출물은 저장소에 포함하지 않는다.

## 먼저 읽을 문서

- [[SPEC]]: `status:: main`, 벤치마크의 사람용 정본
- [`contracts/benchmark.v1.json`](contracts/benchmark.v1.json): 승인된 수량·분할·실험 조건의 기계 판독 스냅샷
- [`contracts/routes.v1.json`](contracts/routes.v1.json): 20개 Route ID, facet, Scene Card와 경계 규칙
- [`contracts/dataset.schema.json`](contracts/dataset.schema.json): 향후 JSONL 레코드 계약
- [`contracts/run-manifest.schema.json`](contracts/run-manifest.schema.json): 실제 실행 증거의 manifest 계약
- [[contracts/DATA_AUTHORING]]: 문항 생성과 독립 검증 절차
- [[CHANGELOG]]: 계약 변경 이력
- [[IMPLEMENTATION]]: 파이프라인, 실행 순서, 강제되는 불변조건
- [[reports/route-threshold-study-2026-08-07]]: 전역·라우트별 threshold 회고 실험 결과와 다음 Frozen 계약

## Source of truth 경계

- 제품·연구 의도와 운영 규칙은 `SPEC.md`가 정본이다.
- 정확한 Route ID와 Scene Card 문자열은 `contracts/routes.v1.json`이 실행 계약이다.
- 실제 실행에 사용된 데이터·모델·프롬프트·환경은 각 run manifest가 증거다.
- 점수와 해석은 향후 결과 보고서에 기록하며 `SPEC.md`에 섞지 않는다.

## 실행 단계

- 설치: `uv sync --project ai/facetroutebench`
- 계약 검증: `uv run --project ai/facetroutebench frbench validate-contracts`
- 전체 명령과 순서: `IMPLEMENTATION.md`

생성 데이터, 임베딩, 원시 추론 로그와 결과는 `ai/facetroutebench/.artifacts/` 아래에만 둔다. 고정 데이터셋을 Git에 넣으려면 동결 후 해시와 내용을 별도로 검토하고 추적 경로로 옮긴다.
