status:: active
last_reviewed:: 2026-08-09

# ToolRouteBench

EmbeddingGemma 기반 multi-label Tool Router가 현재 Regex Router보다 일반
대화를 Tool로 잘못 활성화하지 않으면서 단일 Tool 요청을 더 잘 구분할 수
있는지 확인하는 연구 하니스다.

Pilot 데이터 생성, group-aware 5-fold OOF 후보 선택과 봉인 Holdout 1회 평가를
완료했다. Embedding 후보는 분류 품질을 높였지만 NORMAL 오활성률을 현재 Regex
기준선보다 낮추지 못했다. Pilot의 Regex 대비 비열등 계약은 충족했지만 절대
오활성률 45.83%는 제품 교체 근거로 부족하다. 이 연구는 MVP P0로 계속하며,
현재 Swift `KoreanNativeToolRouter`는 제품 경로와 고정 비교 기준선으로
유지한다.

## 먼저 읽을 문서

- [`SPEC.md`](SPEC.md): Pilot 연구의 사람용 정본
- [`contracts/benchmark.v1.json`](contracts/benchmark.v1.json): 수량·실험군·선택 규칙의 기계 판독 계약
- [`contracts/tools.v1.json`](contracts/tools.v1.json): 7개 Tool ID와 의미
- [`contracts/dataset.schema.json`](contracts/dataset.schema.json): JSONL 문항 계약
- [`IMPLEMENTATION.md`](IMPLEMENTATION.md): 구현 상태와 실행 순서
- [`RESULTS.md`](RESULTS.md): Pilot 봉인 Holdout 결과와 MVP 결정
- [`CHANGELOG.md`](CHANGELOG.md): 계약 변경 이력

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
