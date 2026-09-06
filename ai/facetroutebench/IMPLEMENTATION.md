status:: active

# FacetRouteBench 실행 하니스

## 현재 상태

- v1 데이터: 정본 입력 누락으로 무효, 사용 금지
- v3 GENERAL Authoring 데이터 생성 및 새 Frozen 실험: 안 함
- v3 파이프라인·러너·계약 테스트: 준비됨
- iPhone 런너: 후속 범위, `pending`

## 강제되는 계약

- 계획은 468 Authoring(전문 228 + GENERAL 240) + 696 Dev + 696 Frozen + 60 Context Challenge, 총 1,920건이다.
- 생성자, 정본 검증자, 블라인드 라우트 검증자는 각각 독립 `codex exec --ephemeral` 세션이다.
- 세 세션은 `gpt-5.6-sol`, reasoning effort `medium`으로 고정된다.
- 생성자와 정본 검증자는 앱 정본 `persona_core.md` 원문을 받으며 계획과 manifest에 SHA-256을 기록한다.
- 생성자에게 Scene Router와 Scene Card는 제공하지 않는다.
- `shared_daily`, `narrative`, `mixed` domain은 계획 단계에서 고정되며 생성자가 선택하지 않는다.
- 두 검증자에게는 제작 라벨·facet·난이도를 노출하지 않으며, 정본 검증을 통과한 후보만 블라인드 라우트 검증으로 보낸다.
- 생성, 정본 검증, 블라인드 검증, 중복 감사는 호출 단위로 체크포인트를 저장하여 같은 명령으로 재개할 수 있다.
- Frozen은 Dev에서 선택한 후보·판정 규칙·Frozen 파일 해시·Route 계약 해시가 일치해야 한다.
- 품질 런은 clean Git worktree에서만 실행되며 JSON Schema를 통과한 run manifest를 남긴다.
- Gemma 기준선은 앱과 같은 프롬프트, 입력 wrapper, 최근 6 turn, temperature 0, thinking off, invalid/multiple label → `GENERAL`을 사용한다.
- EmbeddingGemma는 등록된 seq256 mixed-precision 아티팩트, classification prefix, 768차원, cosine, max similarity를 사용한다.

## 1. 설치와 계약 검증

```bash
uv sync --project ai/facetroutebench
uv run --project ai/facetroutebench frbench validate-contracts
```

## 2. 데이터 제작

```bash
FACET_WORK=ai/facetroutebench/.artifacts/authoring-v3
uv run --project ai/facetroutebench frbench create-plan --output "$FACET_WORK/plan.json"
uv run --project ai/facetroutebench frbench generate-candidates --plan "$FACET_WORK/plan.json" --output "$FACET_WORK/candidates.jsonl" --calls "$FACET_WORK/generation-calls.jsonl"
uv run --project ai/facetroutebench frbench canon-validate --candidates "$FACET_WORK/candidates.jsonl" --accepted "$FACET_WORK/canon-accepted.jsonl" --rejected "$FACET_WORK/canon-rejected.jsonl" --calls "$FACET_WORK/canon-validation-calls.jsonl"
uv run --project ai/facetroutebench frbench blind-validate --candidates "$FACET_WORK/canon-accepted.jsonl" --accepted "$FACET_WORK/accepted.jsonl" --rejected "$FACET_WORK/rejected.jsonl" --calls "$FACET_WORK/validation-calls.jsonl"
uv run --project ai/facetroutebench frbench refill-shortages --plan "$FACET_WORK/plan.json" --candidates "$FACET_WORK/candidates.jsonl" --generation-calls "$FACET_WORK/generation-calls.jsonl" --canon-accepted "$FACET_WORK/canon-accepted.jsonl" --canon-rejected "$FACET_WORK/canon-rejected.jsonl" --canon-calls "$FACET_WORK/canon-validation-calls.jsonl" --accepted "$FACET_WORK/accepted.jsonl" --rejected "$FACET_WORK/rejected.jsonl" --validation-calls "$FACET_WORK/validation-calls.jsonl" --generation-workers 128
uv run --project ai/facetroutebench frbench coverage-report --accepted "$FACET_WORK/accepted.jsonl"
uv run --project ai/facetroutebench frbench shortlist-duplicates --accepted "$FACET_WORK/accepted.jsonl" --output "$FACET_WORK/duplicate-pairs.jsonl"
uv run --project ai/facetroutebench frbench audit-duplicates --pairs "$FACET_WORK/duplicate-pairs.jsonl" --output "$FACET_WORK/duplicate-decisions.jsonl" --calls "$FACET_WORK/duplicate-calls.jsonl"
uv run --project ai/facetroutebench frbench freeze-dataset --accepted "$FACET_WORK/accepted.jsonl" --duplicate-audit "$FACET_WORK/duplicate-decisions.jsonl" --output-dir "$FACET_WORK/dataset" --dataset-version 3.0.0
uv run --project ai/facetroutebench frbench validate-dataset --dataset-dir "$FACET_WORK/dataset"
```

생성·정본 검증·블라인드 검증·중복 감사 명령은 기존 출력 묶음이 모두 있으면 처리 완료 ID를 건너뛰고 재개한다. 일부만 있으면 provenance가 섞이지 않도록 실패한다.

초기 oversample factor는 계약의 `1.5`로 고정한다. `refill-shortages`는 검증을 통과한 수가 부족한 `authoring_task_id × domain`만 부족 수량만큼 다시 생성하고 동일한 Canon·블라인드 검증을 수행한다. `--generation-workers`는 독립 생성 호출의 동시성만 바꾸며 데이터 계약은 바꾸지 않는다. 이 고정 rejection sampling은 최대 5 round이며 중간에 factor, 프롬프트 또는 계약을 바꾸지 않는다. 이후에도 shortage cell이 남으면 해당 v3 제작은 실패하고, 모든 cell이 채워지기 전에는 동결할 수 없다.

실행 시간만 단축할 필요가 있으면 `--task-start`/`--task-end`로 계획의 서로 겹치지 않는 반개 구간을 별도 출력에서 실행한다. 구간 결과를 합칠 때는 `candidate_id`와 `task_id`의 중복이 없음을 검증해야 한다.

## 3. EmbeddingGemma 실행 순서

`FACET_MODEL`/`FACET_TOKENIZER`는 `ai/models/runtime-models.json`에 등록된 파일이어야 하며 byte length와 SHA-256을 모두 검증한다.

```bash
FACET_MODEL=/absolute/path/to/embeddinggemma.tflite
FACET_TOKENIZER=/absolute/path/to/tokenizer.model
uv run --project ai/facetroutebench frbench prepare-embedding-inputs --dataset-dir "$FACET_WORK/dataset" --output "$FACET_WORK/embedding-inputs.jsonl"
uv run --project ai/facetroutebench frbench extract-embeddings --inputs "$FACET_WORK/embedding-inputs.jsonl" --model "$FACET_MODEL" --tokenizer "$FACET_TOKENIZER" --output-dir "$FACET_WORK/embeddings-warm" --runtime-mode warm
FACET_EMBEDDINGS="$FACET_WORK/embeddings-warm/embeddings.jsonl"
uv run --project ai/facetroutebench frbench run-embedding-dev --dev "$FACET_WORK/dataset/dev.v3.jsonl" --embeddings "$FACET_EMBEDDINGS" --output-dir "$FACET_WORK/embedding-dev"
uv run --project ai/facetroutebench frbench select-embedding-candidate --dev-summary "$FACET_WORK/embedding-dev/dev_summary.json" --frozen "$FACET_WORK/dataset/frozen.v3.jsonl" --output "$FACET_WORK/frozen-selection.json"
uv run --project ai/facetroutebench frbench run-embedding-frozen --selection "$FACET_WORK/frozen-selection.json" --frozen "$FACET_WORK/dataset/frozen.v3.jsonl" --embeddings "$FACET_EMBEDDINGS" --output-dir "$FACET_WORK/embedding-frozen"
uv run --project ai/facetroutebench frbench run-embedding-context --selection "$FACET_WORK/frozen-selection.json" --context "$FACET_WORK/dataset/context_challenge.v3.jsonl" --embeddings "$FACET_EMBEDDINGS" --output-dir "$FACET_WORK/embedding-context"
```

Dev에서는 기존 네 threshold 후보와 `utterance_prototype_vs_general` 직접 경쟁 후보를 비교한다. GENERAL 240개는 Authoring split에서만 prototype으로 로드하며 Dev/Frozen GENERAL 문항을 prototype으로 사용하지 않는다. Frozen에서는 selection lock의 한 후보만 허용한다.

라우트별 threshold 탐색은 전역 기준선과 별도 비교 명령으로 수행한다. 이 명령은 Dev에서 5-fold 교차검증으로 shrinkage와 동시 합격 중재 규칙을 선택하고, 전체 Dev로 19개 threshold를 재적합한다. 이미 열람한 Frozen을 넘기면 결과는 회고적 탐색일 뿐 새 Frozen 확인으로 간주하지 않는다.

```bash
uv run --project ai/facetroutebench frbench compare-route-thresholds \
  --dev "$FACET_WORK/dataset/dev.v3.jsonl" \
  --frozen "$FACET_WORK/dataset/frozen.v3.jsonl" \
  --embeddings "$FACET_EMBEDDINGS" \
  --output-dir "$FACET_WORK/threshold-comparison"
```

## 4. Gemma 기준선

`FACET_GEMMA`는 registry의 Gemma 4 E2B IT `.litertlm` 파일이어야 한다. 하니스는 Python 3.12에서 계약·집계를 담당하고, `LITERT_PYTHON`은 격리된 worker에서 추론만 담당한다.

```bash
FACET_GEMMA=/absolute/path/to/gemma-e2b-it.litertlm
LITERT_PYTHON=/path/to/litert-environment/bin/python
uv run --project ai/facetroutebench frbench run-gemma --dataset "$FACET_WORK/dataset/dev.v3.jsonl" --model "$FACET_GEMMA" --output-dir "$FACET_WORK/gemma-dev-controlled" --workers 2 --runtime-python "$LITERT_PYTHON"
uv run --project ai/facetroutebench frbench run-gemma --dataset "$FACET_WORK/dataset/frozen.v3.jsonl" --model "$FACET_GEMMA" --output-dir "$FACET_WORK/gemma-frozen-controlled" --workers 2 --runtime-python "$LITERT_PYTHON"
uv run --project ai/facetroutebench frbench run-gemma --dataset "$FACET_WORK/dataset/context_challenge.v3.jsonl" --model "$FACET_GEMMA" --output-dir "$FACET_WORK/gemma-context-current" --no-include-history --workers 2 --runtime-python "$LITERT_PYTHON"
uv run --project ai/facetroutebench frbench run-gemma --dataset "$FACET_WORK/dataset/context_challenge.v3.jsonl" --model "$FACET_GEMMA" --output-dir "$FACET_WORK/gemma-context-history" --include-history --workers 2 --runtime-python "$LITERT_PYTHON"
```

병렬 실행은 데이터셋을 독립 worker shard로 나누며 각 worker는 정확한 배포 `.litertlm`을 한 번 로드한다. worker stdout/stderr는 `.workers/` 로그로 분리해 파이프 backpressure를 방지하고, 문항별 JSONL을 즉시 기록해 중단 후 같은 명령으로 재개할 수 있다. `--workers`는 처리량만 바꾸며 입력·샘플링·점수 계약은 바꾸지 않는다.

## 5. 지연시간과 실행 게이트

`run-gemma --run-kind latency --runtime-mode warm|cold --repeats N`과 `extract-embeddings --runtime-mode warm|cold`로 원시 측정치를 만든다. Warm 집계는 모델 로드를 제외하고 Cold는 각 표본의 로드 시간을 포함한다. p50/p95는 linear interpolation을 사용한다.

```bash
uv run --project ai/facetroutebench frbench summarize-latency --predictions /path/to/predictions.jsonl --router-family gemma_generative --runtime-mode warm --output /path/to/latency.json
uv run --project ai/facetroutebench frbench validate-run-manifest --manifest /path/to/run_manifest.json
```

품질 실행 전에는 하니스와 고정 데이터셋을 커밋하고, `git status --porcelain`이 비어 있어야 한다. Frozen 결과를 본 후 해당 버전을 재튜닝에 사용하지 않는다.
