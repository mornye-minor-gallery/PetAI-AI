status:: active

# FacetRouteBench

Gemma 생성형 Scene Router와 EmbeddingGemma 유사도 Router의 20개 라우트 분류 품질 및 Router 단독 지연시간을 비교하기 위한 연구 계약이다.

현재 단계는 **계약 확정**이다. 데이터셋, 실행 코드, 모델 파일, 실험 결과는 아직 포함하지 않는다.

## 먼저 읽을 문서

- [[SPEC]]: `status:: main`, 벤치마크의 사람용 정본
- [`contracts/benchmark.v1.json`](contracts/benchmark.v1.json): 승인된 수량·분할·실험 조건의 기계 판독 스냅샷
- [`contracts/routes.v1.json`](contracts/routes.v1.json): 20개 Route ID, facet, Scene Card와 경계 규칙
- [`contracts/dataset.schema.json`](contracts/dataset.schema.json): 향후 JSONL 레코드 계약
- [`contracts/run-manifest.schema.json`](contracts/run-manifest.schema.json): 실제 실행 증거의 manifest 계약
- [[contracts/DATA_AUTHORING]]: 문항 생성과 독립 검증 절차
- [[CHANGELOG]]: 계약 변경 이력

## Source of truth 경계

- 제품·연구 의도와 운영 규칙은 `SPEC.md`가 정본이다.
- 정확한 Route ID와 Scene Card 문자열은 `contracts/routes.v1.json`이 실행 계약이다.
- 실제 실행에 사용된 데이터·모델·프롬프트·환경은 각 run manifest가 증거다.
- 점수와 해석은 향후 결과 보고서에 기록하며 `SPEC.md`에 섞지 않는다.

## 현재 포함하지 않는 것

- Authoring, Dev, Frozen, Context Challenge 데이터 본문
- 데이터 생성·검증 실행기
- Gemma 또는 EmbeddingGemma Router 구현
- 임베딩 캐시와 모델 가중치
- Mac 및 iPhone 측정 결과
