# ToolRouteBench Pilot 결과

status:: active
last_reviewed:: 2026-08-09

## 결정

Pilot Embedding 후보는 현재 Swift Regex 기준선보다 도구 분류 품질을 높였지만,
최우선 안전 지표인 NORMAL 오활성률은 개선하지 못했다. 따라서 이 후보는
제품에 통합하지 않는다. ToolRouteBench는 MVP P0로 계속하고, 새 데이터에서
안전 gate를 통과한 후보만 feature flag 뒤의 Swift 검증으로 넘긴다.

## 봉인 Holdout 결과

평가는 192건 Holdout과 잠근 후보 하나로 2026-08-08에 한 번 실행했다.

| 평가 | Exact match | Macro-F1 | Hamming loss | NORMAL 오활성률 |
| --- | ---: | ---: | ---: | ---: |
| Embedding `embedding-09` | 85.94% | 92.44% | 2.01% | 11/24 (45.83%) |
| 고정 Regex 기준선 | 63.02% | 73.94% | 5.28% | 11/24 (45.83%) |

Embedding 후보의 exact match와 Macro-F1 개선은 확인됐지만, 두 방식 모두 일반
대화 24건 중 11건에서 Tool을 잘못 활성화했다. 사전 등록한 Pilot 계약의
상대 조건인 `normal_false_activation_rate_lte_regex`는 동률로 충족했다.
그러나 절대 오활성률이 높고 제품용 상한은 사전 등록되지 않았으므로, 이
결과를 제품 준비 완료나 Router 교체 근거로 해석하지 않는다.

## 재현 조건

- benchmark/dataset version: `0.1.0`
- development: 360건 (`authoring` 168건, `dev` 192건)
- development dataset SHA-256:
  `3dd72ee7237b2546a80a8d3c979efe650cb5bc2e071940466ea6416aeed488e0`
- Dev split SHA-256:
  `7f65256a33f10029ed30e66f7ad91fa1e1a0e34f6146534ddac4c2d9e4871b63`
- Holdout: 192건
- Holdout SHA-256:
  `0c1de17e1092e6562617868f787a11e409bb6c0472841ba3e778d801460a1bb3`
- candidate: `embedding-09`, utterance prototype + maximum similarity +
  tool별 cross-validation shrink threshold
- candidate SHA-256:
  `7d20c71d29447e9b9c5d2d20b03f3b11a95d6abad323247c80d882d1432f2609`
- model: `embeddinggemma-300m-seq256`, revision
  `870cbe05ef460385363c6b574c851ae5d8989ce3`
- model SHA-256:
  `37115ef7bff76cd37dd86abe503ff511b1032bf85fc624a85c49c84899e92bc5`
- embedding: 768차원, sequence length 256
- runtime: `ai-edge-litert` 2.1.3, CPU,
  `macOS-26.5.1-arm64-arm-64bit`
- Holdout lock: 후보 선택 후 재튜닝·재사용 없음

원시 생성 데이터, 임베딩과 run manifest는 Git에 넣지 않는 로컬
`ai/toolroutebench/.artifacts/pilot-v0.1.0/`에 보존한다. 위 해시는 커밋 가능한
결과 요약과 로컬 증거를 연결한다.

## MVP P0 다음 실험

1. Pilot 데이터와 Holdout은 수정하지 않고 새 calibration/holdout을 만든다.
2. 일반 대화, 부정·가정, 도메인 단어만 포함한 hard negative를 보강한다.
3. 새 Holdout을 보기 전에 NORMAL 오활성률 상한, Regex 대비 개선 조건과
   도구 분류 비회귀 조건을 등록한다.
4. actionability gate, positive-normal margin, multi-tool conflict margin과
   Regex veto를 Dev에서 비교한다.
5. 후보 하나만 잠가 새 Holdout에서 한 번 평가한다.
6. 안전 제약을 통과한 경우에만 Swift feature flag, Python-Swift 판정 일치와
   iPhone E2E를 검증한다.

## 검증과 미검증 범위

로컬 재현 검증 명령은 다음과 같다.

```bash
uv run --project ai/toolroutebench trbench validate-contracts
uv run --project ai/toolroutebench python -m unittest discover \
  -s ai/toolroutebench/tests -v
git diff --check
```

- 검증됨: 계약, 데이터·모델·후보 해시, Mac CPU 품질 평가
- `UNVERIFIED`: iPhone 지연시간·메모리·발열, Swift 제품 통합,
  권한·확인·취소·중복 실행 방지 E2E
- 실제 사용자 대화 로그는 수집하거나 평가 입력으로 사용하지 않았다.
