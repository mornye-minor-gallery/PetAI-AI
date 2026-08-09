status:: main

# ToolRouteBench Pilot 명세

version:: 0.1.0
benchmark_id:: toolroutebench
tool_contract:: ./contracts/tools.v1.json
benchmark_contract:: ./contracts/benchmark.v1.json
dataset_schema:: ./contracts/dataset.schema.json
run_manifest_schema:: ./contracts/run-manifest.schema.json

## 1. 목적

현재 7개 네이티브 Tool을 EmbeddingGemma 기반 multi-label Router만으로
분류했을 때, 현재 Regex Router보다 일반 대화 오활성화를 늘리지 않으면서
단일 Tool 분류 성능을 개선할 수 있는지 확인한다.

본 Pilot은 가능성 확인 연구다. 결과가 좋더라도 Swift Router를 자동으로
교체하지 않으며 제품 통합은 별도 브랜치·PR·실기기 검증을 요구한다.

## 2. 범위

### 포함

- 현재 구현된 7개 Tool과 `NORMAL`
- 현재 사용자 발화 하나만 사용하는 한국어 단일 턴 평가
- 7차원 multi-hot 정답
- Regex-only 고정 기준선과 Embedding-only 후보 비교
- 표현 방식, prototype 집계, NORMAL 판정과 threshold 구조 비교
- 21개 Tool pair의 별도 Multi-label Challenge
- Mac에서의 재현 가능한 품질 평가

### 제외

- Swift 제품 Router 변경과 feature flag
- Tool 파라미터 생성 정확도
- 네이티브 실행, 권한, 사용자 확인 UI와 iPhone QA
- 최근 대화 문맥을 결합한 라우팅
- 의미가 애매한 단일 요청의 clarification 정책
- 운영 threshold 확정
- 실제 서비스 비율을 모사한 NORMAL-heavy 평가

## 3. Tool과 출력 계약

정답은 `contracts/tools.v1.json` 순서의 7차원 multi-hot이다.

```text
활성 Tool 0개  -> NORMAL
활성 Tool 1개  -> 해당 Tool
활성 Tool 2개+ -> CONFLICT
```

multi-hot은 사용자가 실제로 여러 작업을 명시한 경우에만 사용한다. 하나의
요청이 여러 방식으로 해석될 뿐이면 `AMBIGUOUS`이며 데이터셋에 채택하지
않는다. 파라미터가 빠져도 실행 의도가 명확하면 해당 Tool을 정답으로 둔다.

## 4. 데이터 계약

### 4.1 Authoring

각 Tool의 positive prototype은 12개다.

| 유형 | Tool당 수량 |
| --- | ---: |
| `direct` | 3 |
| `natural` | 3 |
| `missing_parameter` | 3 |
| `noisy` | 3 |

후보 B의 대조 학습을 위해 Tool별 `NORMAL` prototype도 12개 둔다.

| 유형 | Tool당 수량 |
| --- | ---: |
| `mention_or_past` | 2 |
| `negation` | 2 |
| `capability_or_meta` | 2 |
| `quoted_or_third_party` | 2 |
| `hypothetical_or_wish` | 2 |
| `semantic_boundary` | 2 |

Authoring은 7개 Tool positive 84개와 Tool별 대조 `NORMAL` 84개, 총
168개이며 평가 점수에는 포함하지 않는다.

### 4.2 Dev와 Pilot Holdout

두 분할은 각각 192개다.

- 각 Tool은 `direct`, `natural`, `missing_parameter`, `noisy`를 6개씩,
  Tool당 24개 사용한다.
- `NORMAL`은 여섯 hard-negative 유형을 4개씩, 총 24개 사용한다.
- Tool 168개와 `NORMAL` 24개를 합쳐 분할당 192개다.

### 4.3 Multi-label Challenge

- 7개 Tool의 순서 없는 두 개짜리 조합 21개를 모두 계획한다.
- 조합마다 `direct`, `natural`, `noisy` 한 문장씩 총 63개를 둔다.
- 각 문장은 정확히 두 Tool 요청을 명시해야 한다.
- 이 결과는 주 점수, threshold 튜닝과 후보 선택에 사용하지 않는다.

### 4.4 누출 방지

- 모든 문장에 `expression_family_id`를 지정한다.
- 같은 표현 계열은 Authoring, Dev, Holdout을 넘지 못한다.
- 실제 앱에서 발견한 실패 문장은 별도 Regression 분할로 보존한다.
- Holdout은 후보·threshold·파일 SHA-256을 잠근 뒤 선택 후보 하나로 한 번만
  실행한다.
- Holdout을 보고 수정하면 기존 Holdout은 Dev로 강등하고 새 버전을 만든다.

## 5. 생성과 독립 검증

- 실제 실패 유형을 seed로 사용하되 원문은 자동으로 평가 정답이 되지 않는다.
- 생성, Tool 계약 검증, 라벨을 숨긴 multi-label 블라인드 검증은 서로 다른
  Codex CLI 세션에서 수행한다.
- 세 세션은 `gpt-5.6-sol`, reasoning effort `medium`으로 고정한다.
- 블라인드 검증 결과가 제작 multi-hot과 정확히 같고 `AMBIGUOUS`가 아닌
  문장만 채택한다.
- 사람이 탈락 문장을 고쳐 넣지 않는다. 부족한 셀만 같은 고정 조건으로 다시
  생성·검증한다.

## 6. Embedding 후보

EmbeddingGemma는 `ai/models/runtime-models.json`의
`embeddinggemma-300m-seq256` 아티팩트를 사용하고 classification prefix,
768차원 벡터와 cosine similarity를 사용한다. 두 번째 모델 인스턴스를 만드는
제품 변경은 본 Pilot 범위에 없다.

### 6.1 표현 후보

- Tool ID
- 짧은 Tool 의미 설명
- 사용자 발화 prototype
- 설명 + prototype
- positive prototype vs Tool별 대조 `NORMAL`

기존 Tool parameter prompt는 라우팅과 책임이 다르므로 후보에 넣지 않는다.

### 6.2 prototype 집계

- `max_similarity`
- `centroid_similarity`
- `top3_mean_similarity`

단일 벡터인 Tool ID와 의미 설명에는 prototype 집계를 적용하지 않는다.

### 6.3 NORMAL 판정

후보 A는 각 Tool score가 threshold를 넘는지 독립 판단한다. 후보 B는 Tool별
positive score와 관련 `NORMAL` score의 차이를 독립 판단한다. 활성 Tool이
없으면 `NORMAL`이고 둘 이상이면 `CONFLICT`다.

### 6.4 threshold 구조

- 모든 Tool에 같은 global threshold
- Tool별 raw threshold
- 공통값 방향으로 수축한 Tool별 threshold

모든 후보 조합은 Holdout을 보기 전에 config와 manifest에 사전 등록한다.

### 6.5 과적합 방지와 threshold 추정

세 threshold 구조 모두 동일한 Dev 문장에 threshold를 맞춘 뒤 그 문장을 다시
채점한 값으로 후보를 선택하지 않는다. 후보 선택에는 Dev 5-fold
out-of-fold(OOF) 예측만 사용한다.

1. `expression_family_id`가 같은 문장은 반드시 같은 fold에 둔다.
2. Tool별 positive와 `NORMAL` 비율을 가능한 한 유지하도록 fold를 결정론적으로
   배정한다.
3. 각 fold에서 나머지 4개 fold만 사용해 threshold를 추정한다.
4. 추정한 threshold로 보지 않은 1개 fold를 예측한다.
5. 다섯 fold의 예측을 합쳐 후보별 OOF 지표를 계산한다.

`single_global`, `raw_per_tool`, `cv_shrunk_per_tool` 모두 이 절차를 따른다.
수축형은 각 outer training fold에서 추정한 global threshold와 Tool별 raw
threshold를 config에 고정된 shrinkage로 결합한다. OOF 예측이 완성되지 않거나
어떤 Dev 문장이 정확히 한 번 평가되지 않으면 해당 후보는 fail-closed 처리한다.

OOF로 최종 후보 하나를 선택한 뒤에만 전체 Dev로 그 후보의 배포용 threshold를
한 번 다시 추정한다. 전체 Dev 재학습 결과의 점수는 `training_metrics`, 후보
선택에 사용한 결과는 `oof_metrics`로 분리한다. `training_metrics`는 진단용이며
후보 선택·안전 gate·성능 개선 주장에 사용하지 않는다.

## 7. 평가와 후보 선택

주 분석은 단일 Tool + `NORMAL` 균형 트랙이다.

1. 현재 Swift Regex Router를 같은 Dev에서 평가한다.
2. 모든 Embedding 후보에 대해 5-fold OOF 예측과 `oof_metrics`를 만든다.
3. OOF `NORMAL -> Tool` false activation rate가 Regex보다 높은 후보는
   탈락시킨다.
4. 남은 후보 중 OOF 단일 트랙 Macro-F1이 Regex보다 높은 후보만 유지한다.
5. 그중 OOF Macro-F1이 가장 높은 후보를 고정한다. 동률이면 OOF false
   activation이 낮은 후보, 그다음 안정적인 candidate ID 순으로 결정한다.
6. 조건을 만족하는 후보가 없으면 Pilot 실패로 결론낸다.
7. 선택된 후보만 전체 Dev에서 threshold를 다시 추정하고, 후보 ID·config·최종
   threshold·Dev 파일 SHA-256을 Holdout 실행 전에 잠근다.
8. 잠긴 후보 하나로 Holdout을 한 번만 실행한다.

보조 지표는 Tool별 precision/recall/F1, Tool 요청 recall, exact match,
confusion matrix와 난이도별 성능이다. Multi-label Challenge는 subset
accuracy, micro/macro F1, hamming loss와 Tool pair별 결과를 별도로 보고한다.

Dev 전체를 다시 채점한 `training_metrics`가 100%여도 OOF 성능이 낮으면 좋은
후보로 보지 않는다. Holdout은 threshold를 조정하는 calibration split이 아니며,
결과를 본 뒤 후보·threshold·prototype을 바꾸면 해당 Holdout은 폐기한다.

## 8. 실패와 재현성

- 임베딩 누락, 차원 불일치, NaN, 손상된 계약과 중복 ID는 실행 전에
  fail-closed 처리한다.
- 낮은 점수는 `NORMAL`이며 Regex나 Gemma Router로 자동 폴백하지 않는다.
- 모델 ID·revision·파일 SHA-256, tokenizer SHA-256, 데이터와 config SHA-256,
  Git commit, runtime과 hardware를 run manifest에 기록한다.
- 모델 가중치, 임베딩 캐시와 원시 실행 결과는 `.artifacts/`에만 둔다.

## 9. 수용 기준

- Given 고정 계약, when `validate-contracts`를 실행하면 7개 Tool, 615개 Pilot
  계획, 후보 목록과 모델 registry 참조가 모두 일치해야 한다.
- Given dataset JSONL, when 검증하면 split 수량, 유형 수량, multi-hot 크기,
  21개 pair coverage와 expression-family 분리가 모두 통과해야 한다.
- Given 동일 query와 prototype, when 세 집계를 반복하면 동일한 유한 점수를
  반환해야 한다.
- Given Regex보다 false activation이 높은 후보, when 후보 선택을 실행하면
  OOF 지표 기준으로 해당 후보가 선택될 수 없어야 한다.
- Given Dev 전체 재채점은 완벽하지만 OOF 성능이 낮은 후보, when 후보 선택을
  실행하면 `training_metrics`가 아니라 `oof_metrics`만 사용해야 한다.
- Given 같은 `expression_family_id`의 문장들, when OOF fold를 배정하면 서로
  다른 fold로 분리되지 않아야 한다.
- Given OOF 실행 결과, when 무결성을 검사하면 모든 Dev 문장이 정확히 한 번만
  검증 fold에서 예측되어야 한다.
- Given Holdout 결과, when 결과 기반 수정이 필요하면 같은 Holdout을 재사용할
  수 없다고 manifest와 보고서에 표시해야 한다.

## 10. 결정과 보류

### 확정

- 사용자와의 PRD 인터뷰, 2026-08-08
- 현재 Tool 계약: `docs/ai/health_alarm_tool_use_poc.md`
- 제품 Tool enum: `ios/EdgeLLM/Sources/EdgeLLM/ToolUse/NativeToolContracts.swift`
- 하니스 구조 참조: `ai/facetroutebench/`

### 보류

| 항목 | 근거가 필요한 이유 | 재검토 시점 |
| --- | --- | --- |
| 제품 Router 교체 | Pilot Holdout과 제품 조건 검증 필요 | Pilot 결과 확정 후 |
| 운영 threshold | 균형 Pilot은 실제 NORMAL 비율이 아님 | NORMAL-heavy calibration 구축 후 |
| 문맥 의존 라우팅 | 현재 입력 단독 성능과 분리 필요 | 단일 턴 Pilot 종료 후 |
| 애매한 요청 clarification | 별도 사용자 상태 계약 필요 | Ambiguity Challenge 설계 시 |
| iPhone 성능 | 연구 하니스는 Mac 품질 평가 | 제품 통합 후보 확정 후 |
