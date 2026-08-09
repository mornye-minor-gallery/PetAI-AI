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

## 3. MVP P0에서 남은 실행 순서

1. Pilot 데이터는 회귀 근거로 보존하고 새 calibration과 Holdout을 만든다.
2. 일반 대화·부정·가정·도메인 단어 hard negative를 보강한다.
3. Holdout을 열기 전에 NORMAL 오활성률 상한, Regex 대비 개선과 분류
   비회귀 조건을 고정한다.
4. Dev에서 actionability gate, positive-normal margin, conflict margin과 Regex
   veto를 비교해 후보 하나만 잠근다.
5. 새 Holdout을 한 번 실행하고 안전 제약을 통과한 경우에만 Swift feature
   flag 뒤에 이식한다.
6. Python-Swift 판정 일치와 iPhone 권한·확인·취소·중복 실행 방지를 검증한다.

실제 사용자 대화 로그는 수집하지 않는다. iPhone 지연시간·메모리·발열과
네이티브 도구 E2E는 아직 `UNVERIFIED`다.
