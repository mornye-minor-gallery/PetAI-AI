status:: active
last_reviewed:: 2026-08-11

# ToolRouteBench

EmbeddingGemma 기반 multi-label Tool Router와 prompt-only Gemma 4 E2B IT가
현재 Regex Router보다 일반 대화를 Tool로 잘못 활성화하지 않으면서 단일 Tool
요청을 더 잘 구분할 수 있는지 확인하는 연구 하니스다.

Pilot 데이터 생성, group-aware 5-fold OOF 후보 선택과 봉인 Holdout 1회 평가를
완료했다. Embedding 후보는 분류 품질을 높였지만 NORMAL 오활성률을 현재 Regex
기준선보다 낮추지 못했다. Pilot의 Regex 대비 비열등 계약은 충족했지만 절대
오활성률 45.83%는 제품 교체 근거로 부족하다. 이 연구는 MVP P0로 계속하며,
Swift `KoreanNativeToolRouter`는 고정 비교 기준선으로만 유지한다. 현재 제품
경로는 2026-08-11 승인에 따라 matched MLP로 실행 가능성을 먼저 거르고,
`CALL`일 때만 `embedding-09`로 도구를 선택한다.

추가한 prompt-only Gemma 회고 비교는 Exact 95.31%, Macro-F1 97.46%로 가장
높았지만, 일반대화 24건 중 9건(37.50%)을 Tool로 잘못 실행했다. 기존
Holdout을 본 뒤 설계한 프롬프트이므로 제품 교체 근거로 사용하지 않는다.

3i4K의 질문·명령을 `CALL`, 나머지 5개 발화 유형을 `NO_CALL`로 바꿔
EmbeddingGemma 768차원 벡터 위에 64-unit MLP head를 학습한 smoke test도
완료했다. 3i4K test 정확도는 88.17%였지만 기존 PetAI Holdout의 일반대화
오활성률은 66.67%(16/24)였다. 발화 형식 분류 데이터만으로는 실제 기능 실행
의도를 학습할 수 없으므로 이 후보도 제품에 통합하지 않는다.

따라서 3i4K 원본 라벨을 PetAI 정답으로 재사용하지 않는다. 대신 official test와
겹치지 않는 train 43,521건 전체를 미라벨 후보 풀로 보존하고, Embedding 상위
후보·완화 임계값·Regex를 합집합으로 모아 PetAI Tool 계약에 맞게 다시 감사할
대상만 좁힌다. 이 단계의 라우터 출력은 검색 근거일 뿐 학습 라벨이 아니다.

HN-OOS에서 PetAI와 가까운 영어 hard negative 175건을 더한 실험은 PetAI
Holdout을 개선하지 못했다. 같은 문장을 Gemma 4 E2B IT로 한국어 번역해
174건을 더하자 NORMAL 오활성은 8.33%까지 줄었지만 Tool 요청 재현율도
70.24%로 떨어졌다. negative만 번역해서 늘리면 한국어 Tool 표현 전체를
거절하는 쪽으로 과보정됐다.

후속 matched 실험에서는 PetAI authoring의 `CALL` 84건과 `NO_CALL` 84건을
확인했다. 기존 Holdout과 문장이 같은 `CALL` 3건은 학습에서 제외하고,
`CALL` 81건·`NO_CALL` 84건과 한국어 HN-OOS 174건을 함께 학습했다. 회고
Holdout에서 Gate Accuracy 94.79%, Tool 요청 재현율 94.64%, NORMAL 오활성률
4.17%를 기록했다. 방향성은 확인했지만 이미 열린 Holdout이므로 확인적 제품
성능으로 해석하지 않는다. 현재 통합은 MVP 실기기 검증을 위한 회고 SOTA 후보
채택이며, 새 Holdout 전까지 연구 상태는 유지한다.

## 먼저 읽을 문서

- [`SPEC.md`](SPEC.md): Pilot 연구의 사람용 정본
- [`contracts/benchmark.v1.json`](contracts/benchmark.v1.json): 수량·실험군·선택 규칙의 기계 판독 계약
- [`contracts/tools.v1.json`](contracts/tools.v1.json): 7개 Tool ID와 의미
- [`contracts/dataset.schema.json`](contracts/dataset.schema.json): JSONL 문항 계약
- [`IMPLEMENTATION.md`](IMPLEMENTATION.md): 구현 상태와 실행 순서
- [`RESULTS.md`](RESULTS.md): Regex·Embedding·Gemma 비교 결과와 MVP 결정
- [`CHANGELOG.md`](CHANGELOG.md): 계약 변경 이력
- [`prompts/gemma-e2b-router-retrospective-v1.md`](prompts/gemma-e2b-router-retrospective-v1.md):
  실행 가능성과 Tool ID를 함께 판정하는 prompt-only 회고 후보

## Source of truth

- 연구 의도와 해석은 `SPEC.md`가 우선한다.
- Tool ID와 의미는 `contracts/tools.v1.json`이 실행 계약이다.
- 수량과 후보 선택 규칙은 `contracts/benchmark.v1.json`이 실행 계약이다.
- 실행 입력·모델·설정·원시 결과는 로컬 `.artifacts/` manifest가 증거이고,
  커밋 가능한 핵심 해시와 결론은 `RESULTS.md`에 고정한다.
- 제품 동작의 정본은 Swift 코드이며 본 연구 결과가 자동으로 제품을 바꾸지
  않는다.

## Pilot 결과

| 봉인 Holdout 192건 | Exact match | Macro-F1 | NORMAL 오활성률 |
| --- | ---: | ---: | ---: |
| Embedding 후보 | 85.94% | 92.44% | 11/24 (45.83%) |
| 고정 Regex 기준선 | 63.02% | 73.94% | 11/24 (45.83%) |

Embedding 후보는 전체 도구 분류를 개선했지만 최우선 안전 지표는 개선하지
못했다. 따라서 Pilot 후보는 제품에 통합하지 않는다. MVP P0에서는 새
calibration/holdout에 hard negative를 보강하고 actionability gate,
positive-normal margin, conflict margin과 Regex veto를 비교한다. 새 Holdout을
보기 전에 안전 상한과 선택 규칙을 고정하며, 이를 통과한 단일 후보만 Swift
feature flag와 iPhone E2E 검증으로 넘긴다.

## Prompt-only Gemma 회고 비교

이미 결과를 확인한 Pilot Holdout 192건에 Gemma 4 E2B IT prompt-only 후보를
추가해 Regex·Embedding과 같은 지표로 비교한다. Prompt는 temperature 0에서
`NORMAL` 또는 Tool ID 하나만 출력하며, 잘못된 형식과 복수 라벨은
`NORMAL`로 fail-closed 처리한다.

이 실행은 Holdout 열람 뒤 설계된 회고 비교이므로 새 후보 선택이나 제품 통합의
확인적 근거로 사용하지 않는다. 목적은 Embedding-only 구조의 오활성 문제가
실행 가능성을 명시적으로 판정하는 생성 모델에서도 재현되는지 관찰하는 것이다.

```bash
litert-lm serve --host 127.0.0.1 --port 9379

uv run --project ai/toolroutebench trbench run-gemma-router \
  --dataset ai/toolroutebench/.artifacts/pilot-v0.1.0/holdout-dataset/holdout.jsonl \
  --model-artifact ~/.litert-lm/models/gemma4-e2b/model.litertlm \
  --output-dir ai/toolroutebench/.artifacts/pilot-v0.1.0/holdout-results/gemma-prompt-retrospective-v1 \
  --runtime-version 0.13.1
```

평가 요청은 원격 전송을 막기 위해 `localhost` 또는 `127.0.0.1`의 LiteRT-LM
서버에만 보낼 수 있다.

## 3i4K actionability MLP smoke test

3i4K의 7개 발화 유형을 다음 두 라벨로 결정적으로 변환한다.

- `CALL`: question, command
- `NO_CALL`: fragment, statement, rhetorical question, rhetorical command,
  intonation-dependent

여기서 `CALL`은 곧바로 네이티브 기능을 실행한다는 뜻이 아니라 기존
multi-label Tool Router로 넘길 후보라는 뜻이다. 원본 공식 test와 겹치는
train/validation 문장은 제거하며, 임계값은 validation macro-F1로만 고른다.

```bash
uv run --project ai/toolroutebench trbench prepare-3i4k-actionability \
  --source-cache-dir ai/toolroutebench/.artifacts/actionability-3i4k-mlp-smoke-v1/sources \
  --output-dir ai/toolroutebench/.artifacts/actionability-3i4k-mlp-smoke-v1/dataset

uv run --project ai/toolroutebench trbench extract-embeddings \
  --inputs ai/toolroutebench/.artifacts/actionability-3i4k-mlp-smoke-v1/dataset/embedding_inputs.jsonl \
  --model /path/to/embeddinggemma-300M_seq256_mixed-precision.tflite \
  --tokenizer /path/to/sentencepiece.model \
  --output-dir ai/toolroutebench/.artifacts/actionability-3i4k-mlp-smoke-v1/embedding-run

uv run --project ai/toolroutebench trbench train-actionability-mlp \
  --public-embeddings ai/toolroutebench/.artifacts/actionability-3i4k-mlp-smoke-v1/embedding-run/embeddings.jsonl \
  --public-embedding-manifest ai/toolroutebench/.artifacts/actionability-3i4k-mlp-smoke-v1/embedding-run/embedding_manifest.json \
  --output-dir ai/toolroutebench/.artifacts/actionability-3i4k-mlp-smoke-v1/mlp-run
```

전체 결과와 PetAI `get_step_count` 분석은 [`RESULTS.md`](RESULTS.md)에 있다.

## 3i4K PetAI 계약 후보 마이닝

기존 `question/command → CALL` 변환은 smoke test용 약한 라벨이다. 예를 들어
질문은 일반 대화일 수 있고, fragment인 `타이머 25분`은 실제 실행 요청일 수
있다. 그래서 아래 파이프라인은 7개 원본 발화 유형을 provenance로만 남기고
PetAI `CALL`/`NO_CALL` 정답을 만들지 않는다.

```bash
uv run --project ai/toolroutebench trbench prepare-3i4k-petai-mining-pool \
  --source-cache-dir ai/toolroutebench/.artifacts/actionability-3i4k-mlp-smoke-v1/sources \
  --output-dir ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/pool

uv run --project ai/toolroutebench trbench extract-embeddings \
  --inputs ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/pool/embedding_inputs.jsonl \
  --model ai/.artifacts/runtime-models/embedding/embeddinggemma-300m/embeddinggemma-300M_seq256_mixed-precision.tflite \
  --tokenizer ai/.artifacts/runtime-models/embedding/embeddinggemma-300m/sentencepiece.model \
  --output-dir ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/embedding-run

uv run --project ai/toolroutebench trbench mine-3i4k-petai-candidates \
  --pool ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/pool/pool.jsonl \
  --pool-manifest ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/pool/pool_manifest.json \
  --query-embeddings ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/embedding-run/embeddings.jsonl \
  --query-embedding-manifest ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/embedding-run/embedding_manifest.json \
  --prototype-embeddings ai/toolroutebench/.artifacts/pilot-v0.1.0/embedding-run/embeddings.jsonl \
  --prototype-embedding-manifest ai/toolroutebench/.artifacts/pilot-v0.1.0/embedding-run/embedding_manifest.json \
  --selected-candidate ai/toolroutebench/.artifacts/pilot-v0.1.0/dev-grid-oof/selected_candidate.json \
  --output-dir ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/mining
```

`candidates.jsonl`은 도구별 Embedding Top-1,000, 기존 임계값보다 0.05 낮춘
후보, Regex 적중의 합집합이다. 별도 Gemma 예측 JSONL이 있으면 선택적으로
합칠 수 있다. `rejected_audit_sample.jsonl`은 탈락 풀에서 원본 7개 라벨별
100건씩 뽑아 검색 누락을 점검한다. 두 파일 모두 감사 전에는 미라벨 상태다.

2026-08-11 전수 실행에서는 43,521건 중 4,905건(11.27%)이 후보로 선택됐고,
38,616건이 탈락했다. 후보 Tool ID는 중복 포함 7,503개이며 도구별 최소
1,000개를 확보했다. 탈락 감사 표본은 정확히 700건이다. 상세 해시와 분포는
[`RESULTS.md`](RESULTS.md)에 기록한다.

후보 자체를 정답으로 쓰지 않고 다음 두 독립 판정을 실행한다. 판정 프롬프트에는
라우터 점수·선택 근거·3i4K 원본 라벨을 넣지 않는다. 두 세션이 같은 Tool 집합을
선택하고 둘 다 `ambiguous=false`일 때만 잠정 합의 라벨로 남긴다.

```bash
uv run --project ai/toolroutebench trbench prepare-3i4k-petai-labeling-queue \
  --mining-manifest ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/mining/mining_manifest.json \
  --output-dir ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/queue

uv run --project ai/toolroutebench trbench run-3i4k-petai-labeling-stage \
  --queue ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/queue/labeling_queue.jsonl \
  --queue-manifest ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/queue/labeling_queue_manifest.json \
  --stage contract \
  --output-dir ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/contract

uv run --project ai/toolroutebench trbench run-3i4k-petai-labeling-stage \
  --queue ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/queue/labeling_queue.jsonl \
  --queue-manifest ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/queue/labeling_queue_manifest.json \
  --stage blind \
  --output-dir ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/blind

uv run --project ai/toolroutebench trbench reconcile-3i4k-petai-labels \
  --queue ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/queue/labeling_queue.jsonl \
  --queue-manifest ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/queue/labeling_queue_manifest.json \
  --contract-manifest ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/contract/labeling_manifest.json \
  --blind-manifest ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/blind/labeling_manifest.json \
  --output-dir ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/reconciliation
```

합의 라벨도 사람 표본 감사 전에는
`dual_session_agreement_pending_human_audit` 상태이며 최종 학습 정본이 아니다.

전수 판정 결과 5,605건 중 5,270건(94.02%)이 합의됐고 335건은 모호하거나
불일치해 제외됐다. 잠정 합의 라벨은 `CALL` 2,018건, `NO_CALL` 3,252건이다.
최종 학습 후보는 모든 CALL을 유지하고 NO_CALL을 같은 2,018건으로 결정적
샘플링한다. NO_CALL의 80%는 마이닝 후보 hard negative, 20%는 탈락 감사
표본으로 구성한다.

```bash
uv run --project ai/toolroutebench trbench prepare-balanced-3i4k-actionability-pool \
  --reconciliation-manifest ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/reconciliation/reconciliation_manifest.json \
  --candidate-no-call-fraction 0.8 \
  --output-dir ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/balanced-pool
```

이 산출물도 사람 승인 전에는
`provisional_balanced_pool_pending_human_approval` 상태다. 3i4K 합의 CALL은
캘린더에 크게 치우치며 `get_step_count`는 0건, `create_timer`는 2건뿐이므로
7개 Tool 분류용 데이터 전체를 대신하지 않는다.

사용자가 실험 진행을 승인한 뒤에는 공백·구두점만 다른 중복을 제거하고,
CALL/NO_CALL 및 Tool 조합을 층화한 80/10/10 데이터로 변환한다. 기존 전체
EmbeddingGemma 벡터를 재사용하므로 임베딩 추론을 다시 실행하지 않는다.

```bash
uv run --project ai/toolroutebench trbench prepare-labeled-3i4k-actionability \
  --balanced-pool-manifest ai/toolroutebench/.artifacts/3i4k-petai-labeling-v1/balanced-pool/balanced_pool_manifest.json \
  --source-embeddings ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/embedding-run/embeddings.jsonl \
  --source-embedding-manifest ai/toolroutebench/.artifacts/3i4k-petai-mining-v1/embedding-run/embedding_manifest.json \
  --output-dir ai/toolroutebench/.artifacts/3i4k-petai-actionability-mlp-v1/dataset-final

uv run --project ai/toolroutebench trbench train-actionability-mlp \
  --public-embeddings ai/toolroutebench/.artifacts/3i4k-petai-actionability-mlp-v1/dataset-final/embeddings.jsonl \
  --public-embedding-manifest ai/toolroutebench/.artifacts/3i4k-petai-actionability-mlp-v1/dataset-final/embedding_manifest.json \
  --petai-train-dataset ai/toolroutebench/.artifacts/pilot-v0.1.0/development-dataset/authoring.jsonl \
  --petai-train-embeddings ai/toolroutebench/.artifacts/pilot-v0.1.0/embedding-run/embeddings.jsonl \
  --petai-train-embedding-manifest ai/toolroutebench/.artifacts/pilot-v0.1.0/embedding-run/embedding_manifest.json \
  --petai-train-mode all \
  --petai-dev-dataset ai/toolroutebench/.artifacts/pilot-v0.1.0/development-dataset/dev.jsonl \
  --petai-dev-embeddings ai/toolroutebench/.artifacts/pilot-v0.1.0/embedding-run/embeddings.jsonl \
  --petai-holdout-dataset ai/toolroutebench/.artifacts/pilot-v0.1.0/holdout-dataset/holdout.jsonl \
  --petai-holdout-embeddings ai/toolroutebench/.artifacts/pilot-v0.1.0/holdout-embedding-run/embeddings.jsonl \
  --config ai/toolroutebench/configs/actionability-3i4k-contract-mlp.v1.json \
  --output-dir ai/toolroutebench/.artifacts/3i4k-petai-actionability-mlp-v1/mlp-run-final-calibrated
```

최종 설정은 제품 분포와 같은 `petai_dev`에서 threshold를 선택하고 `test`와
PetAI Holdout은 선택에 사용하지 않는다. 기존 PetAI Holdout은 이미 열린 세트라
회고 비교용이며 새 비공개 Holdout으로 해석하지 않는다.

### iOS 2단계 Tool Router 산출물

현재 회고 평가에서 안전 지표가 가장 좋았던 HN+PetAI matched MLP와
`embedding-09`를 Swift 런타임 포맷으로 내보낼 수 있다. 원본 `.npz`, 학습
데이터와 임베딩 캐시는 계속 `.artifacts/`에만 두고, 검증된 float32 런타임
가중치·프로토타입·manifest만
`ios/EdgeLLM/Sources/EdgeLLM/Resources/ToolRouting/`에 커밋한다.

```bash
uv run --project ai/toolroutebench \
  python -m toolroutebench.ios_tool_router_export \
  --weights ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/ko-authoring-matched-final-v2/model_weights.npz \
  --result ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/ko-authoring-matched-final-v2/result.json \
  --selected-candidate ai/toolroutebench/.artifacts/pilot-v0.1.0/dev-grid-oof/selected_candidate.json \
  --prototype-embeddings ai/toolroutebench/.artifacts/pilot-v0.1.0/embedding-run/embeddings.jsonl \
  --prototype-embedding-manifest ai/toolroutebench/.artifacts/pilot-v0.1.0/embedding-run/embedding_manifest.json \
  --output-dir ios/EdgeLLM/Sources/EdgeLLM/Resources/ToolRouting \
  --replace
```

Swift는 문장당 classification embedding을 한 번 만들고 `MLP → CALL/NO_CALL`을
먼저 판정한다. `CALL`만 같은 벡터를 `embedding-09`에 전달하며, Regex와 별도
Gemma 라우팅 호출은 제품 경로에서 사용하지 않는다. 이 후보는 열린 Holdout의
회고 SOTA이며 새 미열람 Holdout과 실제 iPhone E2E는 여전히 `UNVERIFIED`다.

## HN-OOS 영어·한국어 보조 학습

HN-OOS 원문은 명시적 라이선스를 찾지 못했으므로 로컬 연구용으로만 내려받고
`.artifacts/` 밖으로 복사하거나 Git에 커밋하지 않는다.

```bash
uv run --project ai/toolroutebench trbench prepare-hnoos-actionability-aux \
  --source-cache-dir ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/sources \
  --output-dir ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/hnoos-dataset

uv run --project ai/toolroutebench trbench translate-hnoos-actionability-aux \
  --dataset ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/hnoos-dataset/dataset.jsonl \
  --dataset-manifest ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/hnoos-dataset/dataset_manifest.json \
  --model-artifact /path/to/gemma-4-E2B-it.litertlm \
  --runtime-version 0.13.1 \
  --output-dir ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/hnoos-ko-translation
```

번역 명령은 `127.0.0.1:9379`의 LiteRT-LM 서버만 허용하며, 등록된 Gemma
artifact의 크기와 SHA-256이 배포 정본과 일치해야 실행된다. 영어·한국어
Embedding 추출 뒤 `train-actionability-mlp`의
`--auxiliary-train-embeddings`와
`--auxiliary-train-embedding-manifest`로 train에만 결합한다. 비교표와 정확한
재현 해시는 [`RESULTS.md`](RESULTS.md)에 있다.

PetAI authoring을 함께 학습할 때는 다음 인자를 추가한다. `call-only`는 실제
요청만, `all`은 도구별 실행·비실행 matched pair를 모두 사용한다. Dev/Holdout과
경로도 함께 전달하면 겹치는 ID·문장·표현군을 학습에서 제외하고 결과
manifest에 남긴다.

```bash
uv run --project ai/toolroutebench trbench train-actionability-mlp \
  --public-embeddings /path/to/3i4k-embeddings.jsonl \
  --public-embedding-manifest /path/to/3i4k-embedding-manifest.json \
  --auxiliary-train-embeddings /path/to/korean-hnoos-embeddings.jsonl \
  --auxiliary-train-embedding-manifest /path/to/korean-hnoos-manifest.json \
  --petai-train-dataset /path/to/authoring.jsonl \
  --petai-train-embeddings /path/to/petai-embeddings.jsonl \
  --petai-train-embedding-manifest /path/to/petai-embedding-manifest.json \
  --petai-train-mode all \
  --petai-dev-dataset /path/to/dev.jsonl \
  --petai-dev-embeddings /path/to/petai-embeddings.jsonl \
  --petai-holdout-dataset /path/to/holdout.jsonl \
  --petai-holdout-embeddings /path/to/holdout-embeddings.jsonl \
  --output-dir /path/to/output
```

## 현재 실행 가능한 검증

```bash
uv sync --project ai/toolroutebench
uv run --project ai/toolroutebench trbench validate-contracts
uv run --project ai/toolroutebench python -m unittest discover \
  -s ai/toolroutebench/tests -v
```

## 생성·실행 진입점

```bash
# 계획만 생성하며 LLM 호출은 하지 않는다.
uv run --project ai/toolroutebench trbench create-plan \
  --output ai/toolroutebench/.artifacts/plan.json

# 새 반복의 실제 생성은 split을 명시한다. Holdout은 별도 세션에서 생성한다.
uv run --project ai/toolroutebench trbench generate-candidates --help

# registry와 SHA가 일치하는 모델만 실행할 수 있다.
uv run --project ai/toolroutebench trbench extract-embeddings --help
uv run --project ai/toolroutebench trbench run-dev-grid --help
```

Dev grid는 현재 Swift Regex Router의 예측을 담은 JSONL을
`--regex-predictions`로 요구한다. `run-regex-baseline`은 현재 Swift 로직을
Python으로 의미 보존 포팅한 기준선을 실행하며, 원본 Swift SHA-256이 달라지면
실행을 차단한다.

```bash
uv run --project ai/toolroutebench trbench run-regex-baseline \
  --dataset ai/toolroutebench/.artifacts/dataset/dev.jsonl \
  --output ai/toolroutebench/.artifacts/regex-dev-predictions.jsonl
```

생성 데이터, 임베딩 캐시와 원시 결과는 `ai/toolroutebench/.artifacts/`
아래에만 두며 Git에 포함하지 않는다. Mac 실행 결과는 라우터 품질 근거일 뿐
iPhone 지연시간·메모리·발열 또는 네이티브 실행 안전성을 증명하지 않는다.
