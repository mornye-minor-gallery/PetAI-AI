status:: active

# ToolRouteBench 구현 및 실행 순서

## 현재 상태

- 사람용 Pilot 명세: 준비됨
- 기계 판독 계약과 schema: 준비됨
- 계약 검증·벡터 집계·채점·후보 선택 골격: 준비됨
- Codex 생성·2단계 독립 검증·동결: development 360건과 Holdout 192건 완료
- EmbeddingGemma 추론·33개 threshold grid·group-aware 5-fold OOF: 완료
- Swift Regex 의미 보존 Python 포트와 예측 JSONL exporter: 완료
- Pilot Holdout: 잠근 후보 하나를 192건에서 1회 실행 완료
- Pilot 결정: NORMAL 오활성률 개선 실패로 제품 통합하지 않음
- Gemma 4 E2B IT prompt-only 회고 비교: 192건 실행 완료, 제품 미통합
- 3i4K binary actionability MLP smoke test: train 2,800 / validation 400 /
  test 600 실행 완료, PetAI NORMAL 오활성 66.67%로 제품 미통합
- HN-OOS 영어 175건·Gemma 한국어 번역 174건 보조 학습: 실행 완료,
  한국어 조건은 오활성 8.33%지만 Tool 재현율 70.24%로 제품 미통합
- PetAI authoring matched 보조 학습: 중복 제외 `CALL` 81 / `NO_CALL` 84와
  한국어 HN 174건 실행 완료, 회고 Holdout 오활성 4.17%·재현율 94.64%
- 3i4K train 43,521건 전체 PetAI 계약 후보 마이닝: 실행 완료,
  미라벨 후보 4,905건·탈락 감사 표본 700건 확보
- 3i4K 후보 이중 독립 라벨링과 exact-agreement 조정: 5,605건 실행 완료,
  잠정 합의 5,270건·미합의/모호 335건
- 3i4K 잠정 균형 actionability 풀: 4,036건 생성 완료, 실험 진행 승인됨
- 정규화 중복 제거·층화 80/10/10 분할과 MLP Tool별 평가: 실행 완료
- 최종 64-unit MLP: 3,385건 학습, 350 iteration 수렴, PetAI dev threshold 0.20
- 3i4K 내부 test accuracy 95.27%, PetAI 회고 Holdout accuracy 93.23%
- Swift 제품 통합과 iPhone 실기기 검증: 미실행

## 1. 환경과 계약 검증

```bash
uv sync --project ai/toolroutebench
uv run --project ai/toolroutebench trbench validate-contracts
uv run --project ai/toolroutebench python -m unittest discover \
  -s ai/toolroutebench/tests -v
```

## 2. Pilot에서 완료한 실행 단계

1. `create-plan`으로 고정 셀 계획을 만들었다.
2. `generate-candidates`를 development와 Holdout의 독립 세션에서 실행했다.
3. `contract-validate`, `blind-validate`를 서로 다른 세션으로 실행했다.
4. `freeze-dataset`으로 development 360건과 Holdout 192건의 SHA를 동결했다.
5. `prepare-embedding-inputs`, `extract-embeddings`로 registry 검증된 벡터를
   만들었다.
6. `run-regex-baseline`으로 SHA가 고정된 Swift Regex 포트 결과를 준비했다.
7. `run-dev-grid`의 group-aware 5-fold OOF로 33개 후보를 비교해
   `embedding-09` 하나를 선택했다.
8. `create-holdout-lock` 뒤 `run-locked-track`을 192건 Holdout에서 한 번
   실행했다.

결과와 입력 해시는 [`RESULTS.md`](RESULTS.md)에 기록한다.

## 3. Prompt-only Gemma 회고 비교

기존 Pilot Holdout은 이미 Embedding 후보 결과를 확인했으므로 새로운 확인적
Holdout으로 재사용할 수 없다. 아래 실행은 동일 192건에서 현재 Regex,
Embedding과 prompt-only Gemma의 동작을 직접 관찰하기 위한 회고 실험이다.

```bash
/path/to/litert-lm serve --host 127.0.0.1 --port 9379

uv run --project ai/toolroutebench trbench run-gemma-router \
  --dataset ai/toolroutebench/.artifacts/pilot-v0.1.0/holdout-dataset/holdout.jsonl \
  --model-artifact ~/.litert-lm/models/gemma4-e2b/model.litertlm \
  --output-dir ai/toolroutebench/.artifacts/pilot-v0.1.0/holdout-results/gemma-prompt-retrospective-v1 \
  --runtime-version 0.13.1 \
  --backend cpu
```

모델 파일의 byte length와 SHA-256은 `ai/models/runtime-models.json`의 배포
정본과 일치해야 한다. 결과에는 전체 품질, difficulty별 정확도, NORMAL
오활성률, 출력 형식 준수율과 Mac 요청 지연시간을 기록한다. 비스트리밍 서버가
제공하지 않는 TTFT와 iPhone 성능은 `UNVERIFIED`로 남긴다.

2026-08-11 실행 결과는 Exact 95.31%, Macro-F1 97.46%, NORMAL 오활성
9/24(37.50%)였다. 전체 품질은 가장 높았지만 안전 지표가 여전히 높고 회고
실험이므로 제품에는 통합하지 않는다. 상세 조건과 해시는
[`RESULTS.md`](RESULTS.md)에 기록한다.

## 4. 3i4K actionability MLP smoke test

3i4K의 질문·명령을 `CALL`, 나머지 발화 유형을 `NO_CALL`로 바꾸고 배포
EmbeddingGemma 벡터 위에 64-unit MLP head를 학습한다. 공식 test와 같은
문장은 train/validation에서 제거하고, 임계값은 validation에서만 선택한다.

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

3i4K test accuracy는 88.17%였지만 PetAI Holdout의 NORMAL 오활성률은
66.67%였다. `get_step_count` 실제 요청 재현율도 20/24(83.33%)에 그쳤다.
실제 실행 의도 대신 발화 형식을 학습한 결과이므로 제품에 이식하지 않는다.

## 5. 3i4K 전체 후보 마이닝

3i4K의 7개 발화 유형은 PetAI 실행 의도 정답이 아니다. 전체 train 43,521건을
미라벨로 유지한 채 `embedding-09` 도구별 Top-K, 완화 임계값과 Regex 적중을
합쳐 사람이 PetAI 계약으로 다시 판정할 고밀도 후보를 만든다. 후보에서 빠진
문장은 원본 라벨별 100건씩 표본 감사한다. 라우터 예측은 정답 라벨로 승격하지
않는다.

실행 명령과 산출물 계약은 [`README.md`](README.md#3i4k-petai-계약-후보-마이닝)에
기록한다. 전수 실행 결과 43,521건 중 4,905건이 후보로 선택됐고, 원본 7개
라벨별 탈락 표본 100건씩 총 700건을 확보했다.

후보와 탈락 표본을 합친 5,605건 큐는 두 개의 독립 Codex 세션이 라우터 근거를
보지 않고 판정한다. 정확히 같은 Tool 집합에 합의하고 둘 다 비모호인 행만
잠정 라벨로 남긴다. 합의 CALL/NO_CALL과 각 partition 표본은 사람이 감사한 뒤
최종 학습 풀로 승격한다.

전수 결과는 합의 5,270건, 미합의·모호 335건이다. 합의 라벨은 `CALL` 2,018,
`NO_CALL` 3,252건이며 탈락 표본 700건에서는 `CALL` 5, `NO_CALL` 691,
미합의 4건이었다. 균형 풀은 CALL 2,018건을 모두 유지하고 NO_CALL 2,018건을
후보 hard negative 80%, 탈락 표본 20%로 결정적 샘플링한다. 이 풀은 사람 승인
전까지 provisional 상태다.

## 6. HN-OOS 영어·한국어 보조 학습

HN-OOS의 CLINC150·HWU64 hard negative 중 PetAI의 알람·타이머·시간·일정
도메인과 가까운 영어 175건을 train-only `NO_CALL`로 준비했다. 같은 데이터를
로컬 Gemma 4 E2B IT로 번역하고 중복을 제거한 한국어 174건도 별도 보조
데이터로 준비했다.

```bash
uv run --project ai/toolroutebench trbench prepare-hnoos-actionability-aux \
  --source-cache-dir ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/sources \
  --output-dir ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/hnoos-dataset

/path/to/litert-lm serve --host 127.0.0.1 --port 9379

uv run --project ai/toolroutebench trbench translate-hnoos-actionability-aux \
  --dataset ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/hnoos-dataset/dataset.jsonl \
  --dataset-manifest ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/hnoos-dataset/dataset_manifest.json \
  --model-artifact ai/.artifacts/runtime-models/chat/gemma-e2b-it/gemma-4-E2B-it.litertlm \
  --runtime-version 0.13.1 \
  --output-dir ai/toolroutebench/.artifacts/actionability-3i4k-hnoos-en-smoke-v1/hnoos-ko-translation
```

영어 원문만 추가하면 PetAI Holdout은 기준선과 같았다. 한국어 번역만 추가하면
NORMAL 오활성은 16/24에서 2/24로 줄었지만 실제 Tool 요청 누락은 5/168에서
50/168로 늘었다. 영어와 한국어를 합쳐도 누락은 53/168이었다. 따라서 다음
후보에서는 도구별 한국어 `CALL`과 같은 의미 경계의 `NO_CALL`을 쌍으로
추가했다.

PetAI authoring 168건은 `CALL` 84건과 `NO_CALL` 84건이다. 기존 Holdout과
동일한 `CALL` 3건을 자동 제외한 뒤 다음 두 조건을 비교했다.

- positive-only: `CALL` 81 + 한국어 HN `NO_CALL` 174
- matched: `CALL` 81 + authoring `NO_CALL` 84 + 한국어 HN `NO_CALL` 174

positive-only는 Tool 재현율을 98.21%로 복구했지만 NORMAL 오활성도 41.67%로
다시 증가했다. matched 조건은 Tool 재현율 94.64%, NORMAL 오활성 4.17%,
Gate Accuracy 94.79%였다. HN을 제외한 matched 조건과 전체 정확도는 같았지만,
HN을 포함하면 오활성이 2건에서 1건으로 줄고 Tool 누락은 8건에서 9건으로
늘었다. 최종 확인적 판단은 새 Holdout에서 해야 한다. 상세 결과와 해시는
[`RESULTS.md`](RESULTS.md)에 기록한다.

## 7. MVP P0에서 남은 실행 순서

1. 3i4K 마이닝 후보와 탈락 표본을 PetAI 계약으로 감사해 새 train 후보를
   만든다.
2. 최종 학습은 `CALL`과 `NO_CALL`을 가깝게 균형화하며 source·표현군 단위로
   train/calibration/Holdout을 분리한다.
3. 이번 matched 조건과 선택 규칙을 잠그고 새 calibration과 Holdout을 만든다.
4. 현재 남은 9개 Tool 누락을 새 train/calibration에서 다룬다. 특히
   `missing_parameter`, `create_timer`, `list_alarms` 경계를 보강한다.
5. MASSIVE 한국어 및 PetAI 계약 기반 직접 요청은 기능별 hard negative와
   matched pair로만 확장한다.
6. Holdout을 열기 전에 NORMAL 오활성률 상한, Regex 대비 개선과 분류
   비회귀 조건을 고정한다.
7. Dev에서 actionability gate, positive-normal margin, conflict margin과 Regex
   veto를 비교해 후보 하나만 잠근다.
8. 새 Holdout을 한 번 실행하고 안전 제약을 통과한 경우에만 Swift feature
   flag 뒤에 이식한다.
9. Python-Swift 판정 일치와 iPhone 권한·확인·취소·중복 실행 방지를 검증한다.

실제 사용자 대화 로그는 수집하지 않는다. iPhone 지연시간·메모리·발열과
네이티브 도구 E2E는 아직 `UNVERIFIED`다.
