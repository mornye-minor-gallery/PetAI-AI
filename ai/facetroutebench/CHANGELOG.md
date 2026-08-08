status:: active

# FacetRouteBench 계약 변경 이력

## Unreleased

- 19개 전문 라우트의 one-vs-rest threshold와 동시 합격 중재 규칙을 비교하는 재현 가능한 러너를 추가했다.
- 라우트별 threshold 과적합을 줄이기 위해 Dev 5-fold 층화 교차검증과 전역 threshold 방향 shrinkage를 추가했다.
- v2 회고 실험에서 선택된 `shrinkage=0.25`, `normalized_margin`은 Frozen Macro-F1 `0.7202 → 0.7257`을 기록했지만, 이미 열람한 Frozen이므로 확인적 결과로 사용하지 않는다.
- v3 Authoring에 GENERAL prototype 240개(일반 120, 전문 라우트별 hard negative 120)를 추가했다.
- `utterance_prototype_vs_general` 후보는 전역 threshold 없이 전문·GENERAL prototype Top-1을 직접 경쟁시킨다.
- GENERAL Authoring도 독립 생성, 정본 검증, 블라인드 라울 검증, 고정 rejection sampling과 manifest 해시를 따른다.
- 동결 시 중복 연결이 적은 후보를 먼저 선택해 앞 split의 대체 가능한 문장이 뒤 split의 필수 후보를 막지 않도록 했다.
- 동결 셀을 후보 여유가 적은 순서로 처리해 대체 불가능한 후보를 먼저 보존한다.
- `PLAYFUL_COMPASS` 부족 셀 재생성에 대한 사용자 승인에 따라 rejection sampling 상한을 실제 수행 횟수인 5 round로 정합화했다.
- 검증 탈락 셀만 동일 조건으로 최대 5회 보충하는 고정 rejection sampling 계약을 추가했다.
- rejection sampling의 독립 생성 호출을 worker 수만큼 병렬 실행할 수 있게 했다.
- 생성 문항이 라우트 판별 기준을 직접 설명하지 않고 실제 친구 사이의 일반 대화처럼 작성되도록 생성 프롬프트를 조정했다.
- 정본 입력 없이 생성된 v1 데이터를 무효화했다.
- 앱의 `persona_core.md` 원문과 SHA-256을 생성 계약에 추가했다.
- 데이터 domain을 `shared_daily`, `narrative`, `mixed`로 재정의하고 계획 단계에서 고정했다.
- 정본 일치 검증과 블라인드 Route 검증을 독립 단계로 분리했다.
- v2 후보는 사람이 고쳐 쓰지 않고 두 검증을 모두 통과한 경우에만 동결할 수 있다.
- 재개 가능한 Codex 제작, 이중 검증, 중복 감사, 결정론적 동결 파이프라인을 추가했다.
- Gemma LiteRT-LM과 EmbeddingGemma 라우팅 러너, Dev 선택 잠금, Frozen 보호, Context Challenge, 지표, 지연시간 집계, run manifest 검증을 추가했다.
- 벤치마크 데이터와 모델 추론 결과는 생성하지 않았다.

## 0.1.0 — 2026-08-06

- FacetRouteBench 정본을 최초 작성했다.
- V14의 20개 Route ID와 Elena Scene Card를 v1 계약으로 스냅샷했다.
- Authoring 228개, Dev 696개, Frozen 696개, Context Challenge 60개의 목표 구성을 확정했다.
- 주 지표를 20-route Macro-F1로 확정했다.
- 초기 Embedding 후보 4종, max-similarity 프로토타입 집계와 공통 cosine 임계값을 확정했다.
- 데이터 생성·독립 검증 모델을 Codex CLI `gpt-5.6-sol`, reasoning `medium`으로 확정했다.
- iPhone 실측을 후속 `pending` 범위로 분리했다.
