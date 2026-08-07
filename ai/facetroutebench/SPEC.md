status:: main

# FacetRouteBench 명세

version:: 0.3.0
benchmark_id:: facetroutebench
route_contract:: ./contracts/routes.v1.json
benchmark_contract:: ./contracts/benchmark.v1.json
dataset_schema:: ./contracts/dataset.schema.json
run_manifest_schema:: ./contracts/run-manifest.schema.json

## 1. 문서의 권한

이 문서는 FacetRouteBench의 목적, 평가 범위, 데이터 구성, 비교 조건, 지표 및 오염 방지 규칙을 정의하는 사람용 정본이다.

실험 점수와 해석은 이 문서에 기록하지 않는다. 실제 실행에 사용된 모델·설정·입력 파일의 SHA-256과 환경 정보는 run manifest에 기록한다.

문서와 기계 판독 계약이 충돌하면 의미와 연구 의도는 이 문서를 우선한다. Route ID 및 Scene Card의 정확한 문자열은 `contracts/routes.v1.json`, 수량과 실험 조건의 정확한 값은 `contracts/benchmark.v1.json`을 우선한다.

## 2. 연구 질문

현재 Gemma 생성형 Scene Router를 EmbeddingGemma 기반 유사도 Router로 교체했을 때, 20개 라우트 분류 품질과 Router 단독 지연시간이 어떻게 달라지는가?

## 3. 범위

### 포함

- 현재 Gemma 생성형 Scene Router 기준선
- EmbeddingGemma 기반 유사도 Router 후보
- 19개 전문 라우트와 `GENERAL`
- 현재 사용자 입력만 사용하는 단일 턴 통제 실험
- 최근 대화 유무에 따른 Context Challenge 어블레이션
- Mac에서의 전체 품질 평가와 Router 단독 Cold/Warm 지연시간 측정

### 제외

- 최종 캐릭터 답변의 품질 평가
- 사용자 입력부터 최종 답변까지의 end-to-end 지연시간
- iPhone 실측 결과
- 벤치 결과에 따른 자동 앱 Router 교체
- 엘레나 페르소나 자체의 역할극 품질 평가
- 앱 Router 구현 교체

## 4. 라우트 계약

`contracts/routes.v1.json`은 현재 앱에 병합된 V14 Router의 20개 Route ID와 의미를 스냅샷한다. 기준 소스는 저장소 커밋 `1fb9ed3`의 Elena Granular Scene Router v8과 Scene Card다.

- 19개 전문 라우트는 6개 coarse facet에 속한다.
- `GENERAL`은 어떤 전문 라우트에도 속하지 않을 때 사용하며 coarse facet은 `null`이다.
- Route ID와 의미는 V14 계약을 유지한다.
- 캐릭터명이 필요한 문구는 현재 정본 이름인 엘레나를 사용한다.
- 세부 라우트가 정답인 단일 턴 문항은 현재 입력만으로 그 라우트를 판정할 수 있어야 한다.

## 5. 데이터셋 구성

| 분할 | 전문 라우트 | GENERAL | 합계 |
| --- | ---: | ---: | ---: |
| Authoring | 228 | 240 | 468 |
| Dev | 456 | 240 | 696 |
| Frozen | 456 | 240 | 696 |
| Context Challenge | - | - | 60 |

전체 고정 데이터 목표는 1,920개다. 생성 과정에서 폐기되는 후보는 이 수에 포함하지 않는다.

### 5.1 Authoring

- 19개 전문 라우트마다 사용자 발화 프로토타입 12개를 둔다.
- `direct`, `natural`, `neighbor` 성격의 표현을 각각 4개씩 구성한다.
- 전문 라우트 prototype은 총 228개다.
- GENERAL prototype은 일반 일상 대화 120개와 19개 전문 라우트 경계 hard negative 120개, 총 240개다.
- GENERAL hard negative는 각각 대조하는 전문 Route ID를 계획에 고정하지만, 생성 결과의 정답은 `GENERAL`이다.
- Authoring은 Router 표현을 구성하는 자료이며 평가 점수 계산에 포함하지 않는다.
- Authoring은 Dev 결과를 근거로 수정할 수 있다.

### 5.2 Dev와 Frozen의 전문 라우트

19개 전문 라우트마다 다음 문항을 구성한다.

- `direct`: 8개
- `natural`: 8개
- `neighbor`: 8개

각 분할은 라우트당 24개, 총 456개다.

### 5.3 GENERAL

Dev와 Frozen 각각에 다음 문항을 포함한다.

- 전문 라우트와 직접 관련 없는 일반 발화: 120개
- 전문 라우트의 단어나 소재를 공유하지만 해당 의도가 아닌 hard negative: 120개

각 분할의 GENERAL은 총 240개다. `GENERAL`은 Authoring centroid 또는 프로토타입 라우트로 만들지 않으며 공통 유사도 임계값을 통한 기각 대상으로 취급한다.

### 5.4 Context Challenge

- 총 60개 다중 턴 시나리오를 둔다.
- 20개 Route ID마다 3개씩 구성한다.
- 마지막 사용자 발화만 보면 모호할 수 있지만 최근 대화를 함께 보면 목표 라우트가 명확해야 한다.
- 결과는 주 Macro-F1에 합산하지 않고 문맥 유무에 따른 진단 지표로만 사용한다.

## 6. 문항 계약

- 문항을 만들기 전에 목표 Route ID를 먼저 정한다.
- 문항 하나에는 정답 Route ID가 정확히 하나만 존재해야 한다.
- 복수 의도 문항은 사용하지 않는다.
- 현재 입력만으로 판정할 수 없는 문항은 단일 턴 Dev/Frozen에 넣지 않는다.
- `neighbor` 문항에는 인접 라우트와 정답을 구분하는 명시적 단서가 있어야 한다.
- 독립 검증이 제작 라벨과 불일치하거나 복수 해석 가능하다고 판정하면 해당 후보를 폐기한다.
- 생성기는 앱 정본 `persona_core.md`를 원문 그대로 입력받으며 해당 파일의 SHA-256을 계획과 manifest에 기록한다.
- 데이터 domain은 생성 전에 계획에 고정하며 `shared_daily`, `narrative`, `mixed`만 사용한다.
- `shared_daily`는 사용자와 엘레나가 함께 생활하고 대화하며 친구로 가까워지는 일상이다.
- 정본 검증이 정체·관계·설정·지식 경계 또는 대화 자연스러움의 충돌을 판정하면 후보를 수정하지 않고 폐기한다.
- 의미가 같은 단순 패러프레이즈와 사실상 중복인 문항은 Authoring, Dev, Frozen 사이를 넘지 못한다.

표현은 짧은 모바일 채팅체, 자연스러운 일상 대화, 감정 표현, 서사적 대화, 존댓말·반말, 생략·완곡 표현, 소량의 오타와 띄어쓰기 오류를 포함할 수 있다. 표현이 다양해도 정답을 가르는 핵심 단서는 보존해야 한다.

## 7. 생성과 독립 검증

- 생성, 정본 검증, 블라인드 라우트 검증은 서로 다른 Codex CLI 세션에서 수행한다.
- 세 세션 모두 `gpt-5.6-sol`, reasoning effort `medium`으로 고정한다.
- 생성 세션은 목표 Route ID와 난이도를 입력받아 후보 문항을 만든다.
- 생성 세션은 정본 `persona_core.md`를 받지만 Scene Router와 Scene Card 원문은 받지 않는다.
- 정본 검증 세션은 정본과 문항만 보고 캐릭터·관계·설정 일치 여부를 판정하며 의도한 Route ID는 보지 않는다.
- 블라인드 라우트 검증 세션은 의도한 정답, 생성 과정, 이전 판정을 보지 않는다.
- 블라인드 라우트 검증 세션은 라우트 계약과 평가할 문항만 보고 정확히 하나의 Route ID 또는 `AMBIGUOUS`를 반환한다.
- 정본 검증을 통과하고 블라인드 검증 Route ID가 제작 Route ID와 정확히 같은 후보만 채택한다.
- 모델 ID, reasoning effort, 생성·검증 프롬프트 SHA-256과 batch ID를 provenance에 기록한다.
- 생성된 문항을 사람이 고쳐 쓰는 단계는 두지 않는다.
- 검증 탈락으로 셀별 목표 수량이 부족하면 동일한 고정 조건으로 부족 수량만 재생성하고 두 검증을 다시 수행한다. 최대 5 round 뒤에도 부족하면 제작 실패로 처리한다.

세부 절차는 `contracts/DATA_AUTHORING.md`를 따른다.

## 8. 실험군

### 8.1 기준선

- 현재 Gemma 생성형 Scene Router

### 8.2 초기 Embedding 후보

1. Scene Card 원문 임베딩
2. 라우트 의미 설명문 임베딩
3. 사용자 발화 프로토타입 임베딩
4. 설명문과 프로토타입을 결합한 임베딩

초기 후보는 탐색의 시작점이며 후보 수의 상한이 아니다. 후속 후보는 Dev에서 한 요소씩 변경하고 설정·입력 파일의 버전과 SHA-256을 기록한다.

### 8.3 프로토타입 점수

- 전문 라우트마다 12개 프로토타입을 사용한다.
- 입력과 각 프로토타입의 cosine similarity를 계산한다.
- 각 라우트의 점수는 해당 라우트 프로토타입 중 가장 높은 `max similarity`다.
- 19개 라우트 점수 중 Top-1을 후보 라우트로 삼는다.

## 9. GENERAL 기각

- 공통 cosine similarity 임계값 하나는 비교 기준선으로 유지한다.
- 기준선은 Top-1 점수가 공통 임계값보다 낮으면 `GENERAL`로 기각한다.
- 공통 임계값은 Dev의 20-route Macro-F1을 기준으로 선택한다.
- Top-1과 Top-2의 margin은 초기 실험에서 사용하지 않는다.
- 최종 후보와 임계값은 Frozen 실행 전에 고정한다.

### 9.1 GENERAL prototype 직접 경쟁 후보

- 19개 전문 라우트의 prototype Top-1과 GENERAL prototype Top-1을 같은 cosine 공간에서 직접 경쟁시킨다.
- 전역 threshold를 적용하지 않고 더 높은 쪽을 예측으로 삼는다.
- GENERAL prototype 240개는 Dev나 Frozen에서 가져오지 않고 독립 Authoring 절차로 생성·검증한다.
- 기존 threshold 방식과 직접 경쟁 방식을 Dev에서 함께 비교하고 하나를 고정한 후 새 Frozen에서 검증한다.

### 9.2 라우트별 threshold 후보

- 19개 전문 라우트마다 Dev의 해당 라우트 대 나머지 문항을 one-vs-rest로 구성한다.
- 각 라우트의 원 threshold는 binary F1이 최대가 되는 cosine 합격선으로 정한다.
- 라우트별 표본 수가 적어 생기는 과적합을 억제하기 위해 원 threshold를 공통 threshold 방향으로 shrink한다.
- shrinkage 강도 `0, 0.25, 0.5, 0.75, 1.0`과 동시 합격 중재 규칙 `raw_score`, `threshold_margin`, `normalized_margin`은 Dev 내부 5-fold 층화 교차검증으로 선택한다.
- 층화 키는 `gold_route_id + difficulty`이며, 각 층은 `case_id` 정렬 후 round-robin으로 fold에 배치한다.
- 여러 라우트가 합격하면 교차검증으로 선택된 중재 규칙을 적용하고, 아무 라우트도 합격하지 않으면 `GENERAL`이다.
- 전체 Dev로 원 threshold를 다시 적합한 뒤 선택된 shrinkage를 적용하고, 그 값과 중재 규칙을 새 Frozen 실행 전에 잠근다.

## 10. 평가 트랙

### 10.1 단일 턴 통제 트랙

Gemma Router와 Embedding Router 모두 현재 사용자 입력만 받는다. 본 트랙의 Macro-F1이 주 품질 지표다.

### 10.2 제품 조건 트랙

- Gemma Router는 기존 제품과 같이 최근 사용자에게 공개된 대화와 현재 입력을 받는다.
- Embedding Router는 현재 입력만 받는다.
- 본 트랙은 실제 교체 조건에서 문맥 손실이 어느 정도인지 진단한다.

### 10.3 Context Challenge 어블레이션

동일한 60개 시나리오에 대해 현재 입력만 제공한 결과와 최근 대화를 포함한 결과를 분리 기록한다. 이 결과는 단일 턴 주 점수와 합치지 않는다.

## 11. 평가 지표

### 주 지표

- 20-route Macro-F1

### 보조 품질 지표

- 전체 정확도
- Route ID별 precision, recall, F1
- `direct`, `natural`, `neighbor`별 Macro-F1
- 6개 coarse facet 정확도
- `GENERAL` precision과 recall
- 잘못된 전문 Scene Card 활성화율
- confusion matrix
- 오류 및 timeout 비율

정답 Route ID가 있는 분류 문제이므로 주 품질 평가에 LLM-as-a-Judge를 사용하지 않는다.

## 12. Dev와 Frozen 절차

1. Gemma 기준선과 모든 Embedding 후보를 Dev에서 평가한다.
2. 표현 방식, 프로토타입과 공통 임계값은 Dev에서만 수정한다.
3. 최종 Embedding 후보 하나와 모든 설정을 고정한다.
4. Frozen에서는 Gemma 기준선과 고정된 Embedding 후보 하나만 실행한다.
5. Frozen 결과를 이용해 Router를 수정하면 해당 데이터는 이후 Dev로 취급한다.
6. 후속 최종 검증에는 새 버전의 Frozen을 생성한다.

이번 1차 연구에는 사전 합격 임계값을 두지 않는다. 품질과 속도 메트릭을 연구 결과로 보고 앱 교체 여부를 후속 결정한다.

## 13. 지연시간 측정

이번 벤치는 Router 단독 지연시간만 측정한다.

- Cold latency
- Warm latency
- p50과 p95
- 문항당 평균 처리시간
- 처리량
- 모델 로드 시간
- 오류와 timeout 비율

Mac에서 전체 품질 평가와 Router 단독 지연시간을 측정한다. 정확한 배포 LiteRT-LM 아티팩트와 runtime을 사용하며 모델 ID, 양자화 방식, 아티팩트 SHA-256, runtime 버전과 backend를 기록한다.

iPhone 실측은 후속 작업이며 현재 상태는 `pending`이다. 향후 QA 기준 기기 1대를 지정해 라우트별 5개, 총 100개 표본을 동일하게 사용하고 Warm 3회와 Cold 5회를 측정한다. 기기 모델, iOS 버전, 배터리와 thermal 상태를 함께 기록한다.

## 14. 재현성과 저장 정책

각 실행의 manifest는 다음을 포함해야 한다.

- Git commit
- 데이터셋 버전, 레코드 수와 SHA-256
- Route 계약과 설정 파일 SHA-256
- 모델 ID, 모델 아티팩트 SHA-256과 checkpoint lineage
- 양자화 또는 QAT variant
- runtime 이름과 버전
- CPU, GPU, NPU backend
- 시작·종료 시각
- 성공, 실패 또는 중단 상태
- 결과 파일 경로와 SHA-256

Git에는 정본 문서, 계약, 작은 고정 데이터셋, 설정, 향후 러너와 테스트를 포함할 수 있다. 모델 가중치, 임베딩 캐시, 원시 추론 로그, 대용량 프로파일과 반복 실행 결과는 `.artifacts/` 아래에 두고 커밋하지 않는다.

## 15. 미정 및 후속 범위

- 실제 QA iPhone 모델과 iOS 버전
- iPhone Router latency, memory, thermal, battery 결과
- Top-1/Top-2 margin 기각 어블레이션
- 프로토타입 6·12·24개 규모 어블레이션
- centroid, Top-K 집계와 contrastive prototype 후보
- 최종 앱 Router 교체 판단과 end-to-end 제품 검증
