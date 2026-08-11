# ToolRouteBench 결과

status:: active
last_reviewed:: 2026-08-11

## 3i4K binary actionability MLP smoke test

2026-08-11에 3i4K 발화 유형을 `CALL`과 `NO_CALL`로 재매핑하고, 배포 정본
EmbeddingGemma의 768차원 벡터 위에 `768 → 64 → 1` MLP head를 학습했다.
`question`과 `command`는 `CALL`, 나머지 5개 유형은 `NO_CALL`이다. 이때
`CALL`은 실제 Tool 실행 확정이 아니라 뒤쪽 Tool Router로 보낼 후보를 뜻한다.

공식 train/validation 원본에서 2,800건 train과 400건 validation을 뽑고,
공식 test에서 600건을 뽑았다. 각 split은 `CALL:NO_CALL=1:1`이다. 원본 자체에
존재하는 동일 문장 누수를 막기 위해 공식 test와 겹치는 583건을
train/validation 후보에서 먼저 제거했다. MLP 임계값 `0.54`는 validation
macro-F1만으로 선택하고 test에서는 고정했다.

| 평가 | 문장 수 | Accuracy | Macro-F1 | NO_CALL 오활성 | CALL 누락 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3i4K validation | 400 | 90.00% | 90.00% | 18/200 (9.00%) | 22/200 (11.00%) |
| 3i4K official test | 600 | 88.17% | 88.17% | 33/300 (11.00%) | 38/300 (12.67%) |
| PetAI Dev | 192 | 88.54% | 69.30% | 15/24 (62.50%) | 7/168 (4.17%) |
| PetAI Holdout 회고 | 192 | 89.06% | 68.60% | 16/24 (66.67%) | 5/168 (2.98%) |

3i4K 안에서는 질문·명령과 나머지 발화 형식을 어느 정도 구분했지만, PetAI로
옮기자 일반대화의 2/3를 Tool 후보로 잘못 통과시켰다. 특히 기능 문의 4/4,
인용·제3자 발화 3/4, 희망·가정 3/4, 부정 3/4를 오활성했다. 3i4K에는
“질문/명령처럼 보이지만 지금 실행 요청은 아닌 문장”이라는 PetAI의 핵심
경계가 충분히 들어 있지 않기 때문이다.

같은 PetAI Holdout을 단순히 `Tool 후보인가`만으로 다시 채점하면 다음과 같다.
Embedding과 Regex의 원래 다중 Tool exact match와는 다른 이진 gate 지표다.

| 후보 | Gate accuracy | Tool 요청 재현율 | NORMAL 오활성률 |
| --- | ---: | ---: | ---: |
| Prompt-only Gemma 4 E2B IT | **95.31%** | **168/168 (100%)** | **9/24 (37.50%)** |
| Embedding multi-label 후보 | 91.15% | 162/168 (96.43%) | 11/24 (45.83%) |
| 3i4K Embedding MLP | 89.06% | 163/168 (97.02%) | 16/24 (66.67%) |
| 고정 Regex 기준선 | 63.02% | 108/168 (64.29%) | 11/24 (45.83%) |

### 걸음 수 조회 `get_step_count`

PetAI Holdout의 실제 걸음 수 조회 24건 중 20건을 `CALL`로 통과시켜 재현율은
83.33%였다. 다음처럼 짧은 직접 질문도 놓쳤다.

- `오늘 지금까지 몇 걸음 걸었어?`
- `나 몇 걸음 걸었어?`

반대로 걸음 수를 언급하지만 조회 요청이 아닌 4건 중 1건을 `CALL`로 잘못
판정했다.

- `“오늘 몇 걸음 걸었지?”라고 물어보려다가 그냥 건강 앱에서 봤어.`

따라서 걸음 수 기능을 포함한 실제 PetAI 도메인에서도 이 head를 실행 gate로
사용할 수 없다.

### 학습 및 재현 증거

- experiment: `3i4k-binary-mlp-smoke-v1`
- 실행 Git commit: `e003a076cc0e210b73843b4d654e12a466404620`
- 3i4K source commit: `cfa90c15f808becafca2d8ef8649b8b71f6bbe71`
- dataset: train 2,800 / validation 400 / test 600
- dataset SHA-256:
  `6ef371e703609f3a0610c1c84fc459428bf241ba7b5382cc05f907b394ec0d42`
- EmbeddingGemma output SHA-256:
  `717cc351c5ba22b141f3ca6b49278bc4f4b3567bbd1d73be0498b1f6222196f2`
- MLP weights: 186,221 bytes, SHA-256
  `7cd1d4f557287dc3dcbaaa8695d2baa2ab36216f187352708c6a49e64e9a8487`
- seed: `20260811`, hidden units: 64, validation-selected threshold: `0.54`
- runtime: Python 3.12.13, scikit-learn 1.9.0, `ai-edge-litert` 2.1.3,
  Mac CPU
- optimizer는 300 iteration 제한에 도달해 수렴 완료 표시는 나지 않았다.
  그러나 train accuracy가 99.86%인데 PetAI NO_CALL 오활성이 66.67%이므로,
  주된 문제는 단순 학습 부족보다 과적합과 데이터 목적 불일치다.
- PetAI Holdout은 이미 공개된 split의 **회고 평가**이며 새 확인적 근거가 아니다.
- `UNVERIFIED`: Core ML/LiteRT head 변환, Swift 통합, iPhone 지연시간·메모리,
  실제 HealthKit 권한 및 `get_step_count` E2E

결론은 3i4K를 사전학습용 보조 데이터로 쓸 수는 있어도, 이것만으로 PetAI의
실행 의도 gate를 만들 수 없다는 것이다. 제품 후보를 다시 만들려면 부정,
인용, 타인 발화, 희망, 기능 문의를 포함한 PetAI 전용 actionability 라벨이
필요하다. 이 MLP는 제품에 통합하지 않는다.

## 영어·한국어 HN-OOS hard negative 보조 학습

3i4K MLP에 hard negative를 함께 학습하면 PetAI 일반대화 오활성이 줄어드는지
확인했다. HN-OOS의 CLINC150·HWU64 파일 2,688건에서 알람, 타이머, 시간,
캘린더와 가까운 19개 원본 intent만 골랐다. 그중 PetAI 기준으로 실제 Tool
요청이거나 경계가 불명확한 6건을 제외하고, 영어 175건을 train-only
`NO_CALL` 보조 데이터로 사용했다. 기존 3i4K validation/test와 PetAI
Dev/Holdout에는 새 문장을 섞지 않았다.

영어 175건은 먼저 원문 그대로 학습했다. 다음으로 배포 정본 Gemma 4 E2B IT를
로컬 LiteRT-LM에서 temperature 0으로 실행해 한국어로 번역했다. 출력 형식과
한글 포함 여부는 자동 검증했지만 사람이 번역 품질을 확정하지는 않았다. 서로
다른 영어 2건이 같은 한국어 문장으로 번역되어 중복 하나를 제거했고, 최종
한국어 보조 데이터는 174건이다.

| 학습 조건 | 추가 `NO_CALL` | 임계값 | 3i4K test Accuracy | PetAI Holdout Gate Accuracy | PetAI Macro-F1 | Tool 요청 재현율 | NORMAL 오활성률 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3i4K 기준선 | 0 | 0.54 | 88.17% | 89.06% | 68.60% | 163/168 (97.02%) | 16/24 (66.67%) |
| + 영어 HN-OOS | 175 | 0.53 | 88.67% | 89.06% | 68.60% | 163/168 (97.02%) | 16/24 (66.67%) |
| + 한국어 번역 | 174 | 0.35 | 87.50% | 72.92% | 63.89% | 118/168 (70.24%) | **2/24 (8.33%)** |
| + 영어와 한국어 | 349 | 0.55 | **89.50%** | 68.75% | 57.74% | 115/168 (68.45%) | 7/24 (29.17%) |

영어 원문만 더했을 때 3i4K test는 0.50%p 올랐지만 PetAI Holdout은 한 건도
순개선되지 않았다. 다국어 EmbeddingGemma를 사용하더라도 영어 hard negative의
미세한 실행 경계가 한국어 제품 문장으로 충분히 전이되지는 않았다.

한국어 번역을 넣자 일반대화 오활성은 66.67%에서 8.33%로 크게 줄었다. 즉
번역된 negative 신호 자체는 분명히 전이됐다. 그러나 실제 Tool 요청 재현율도
97.02%에서 70.24%로 무너졌다. 알람·타이머·일정 주변의 한국어 문장을
`NO_CALL`로만 추가하고 그에 대응하는 직접 실행 요청 `CALL`은 추가하지 않아,
head가 한국어 Tool 도메인 표현 전반을 과도하게 거절한 결과다. 영어와 한국어를
동시에 넣어도 같은 문제가 해결되지 않았다.

따라서 다음 실험은 번역량을 더 늘리는 것이 아니라 **matched positive와
matched negative를 쌍으로 보강**해야 한다. 타이머, 로컬 알림, 알람 목록
조회·수정·삭제, 캘린더, 걸음 수마다 다음 두 부류를 같이 학습한다.

- `CALL`: `20초 타이머 맞춰 줘`, `오늘 몇 걸음 걸었어?`처럼 지금 실행할 요청
- `NO_CALL`: 기능 문의, 과거 언급, 인용, 가정, 희망, 취소·부정처럼 실행하면
  안 되는 유사 문장

공개 데이터는 MASSIVE의 한국어 직접 요청을 후보로 검토하되 현재 PetAI Tool
계약으로 다시 매핑해야 한다. 특히 HN-OOS에는 걸음 수 조회 의도가 없으므로
`get_step_count` 양성·음성 경계는 별도로 보강해야 한다. 현재 번역 데이터는
유용한 negative pool로 보존하지만 세 MLP 모두 제품에는 통합하지 않는다.
PetAI Holdout 수치는 이미 열린 split을 다시 사용한 회고 비교다.

### HN-OOS 실행 및 재현 증거

- 구현 Git commits:
  `d83fa0c4621d21c8b65afef79dd1f0b83750c38e`,
  `997b4fd206c78c4f42811eb6482b805e9059811f`,
  `c1ca653589e40628a5ffa80076164327d744087b`
- HN-OOS source commit:
  `b5a9cdbff3518acf987a509e3545560624d8c1a7`
- 원본 파일 SHA-256: CLINC150
  `dee498b874966c802a7f7612ab282cfbfc4ce87914db68d65ef9699d1e7b692b`,
  HWU64
  `678683308c2feab41f6113c26d9eef2438c2d4c380e16ed9e4767d43d6f64e09`
- 영어 dataset SHA-256:
  `f86d2965053e59f50fde788c92b5ae8efe2473781f6a2a3d8604915e4a97f92f`
- 한국어 dataset SHA-256:
  `cbcf6bcefa601688f05dc701f2ef5b863d6f74f86948e7839b3b09dac55707b6`
- 번역 모델 SHA-256:
  `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`
- 번역 prompt SHA-256:
  `5c09e62b3535f9e905d160299ffecb37abc441ec876e8a2f21a84b578a3ff74d`
- MLP weights SHA-256: 영어
  `2f819adc7fc7338df57bd981a331f21595baafbce9fb72148fee6e02f2280854`,
  한국어
  `dba48ee2d484c24f4cf83ef719560e365b804ff2cbd7f22e56c870872daeaba1`,
  영어+한국어
  `c16f107e6b627322578ebab5ca74a242823a5df7148289edfb91c3ecbc08b125`
- 번역 지연시간: 평균 1,579.5ms, 중앙값 1,419.5ms, Mac CPU
- 원본 저장소에서 명시적 라이선스를 찾지 못해 원문·번역문은 로컬 연구용
  `.artifacts/`에만 두고 Git에 커밋하거나 재배포하지 않는다.
- `UNVERIFIED`: 번역문 사람 검수, 새 미열람 Holdout, Swift/Core ML 변환,
  iPhone 지연시간·메모리와 실제 Tool E2E

## PetAI authoring matched 보조 학습

negative-only 과보정을 고치기 위해 PetAI Pilot authoring을 학습 보조 데이터로
사용했다. 이 split은 실제 Tool 요청 `CALL` 84건과 같은 7개 Tool에 대응하는
`NO_CALL` 84건으로 구성된다. 앞선 설명에서 168건 전부를 positive라고 표현한
것은 잘못이었으며, 정확한 구성은 84:84다.

authoring과 기존 Holdout을 대조하자 다음 `CALL` 3건이 완전히 같은 문장으로
중복돼 있었다.

- `내 걸음 수 좀 확인해 줘.`
- `내일 아침 7시에 알람 맞춰 줘.`
- `내가 만들어 둔 알람 목록 보여줘.`

세 문장은 학습에서 자동 제외하고 exclusion evidence를 결과에 기록했다.
따라서 positive-only 조건은 `CALL` 81건, matched 조건은 `CALL` 81건과
`NO_CALL` 84건을 사용한다. 학습 데이터와 3i4K validation/test, PetAI
Dev/Holdout 사이의 case ID·문장·표현군 중복은 실행 전에 차단한다.

| 학습 조건 | 추가 학습 데이터 | 3i4K test Accuracy | PetAI Holdout Gate Accuracy | Macro-F1 | Tool 요청 재현율 | NORMAL 오활성률 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 3i4K 기준선 | 없음 | 88.17% | 89.06% | 68.60% | 163/168 (97.02%) | 16/24 (66.67%) |
| + 한국어 HN | `NO_CALL` 174 | 87.50% | 72.92% | 63.89% | 118/168 (70.24%) | 2/24 (8.33%) |
| + 한국어 HN + authoring positive | `CALL` 81 + `NO_CALL` 174 | 88.00% | 93.23% | 82.25% | **165/168 (98.21%)** | 10/24 (41.67%) |
| + authoring matched | `CALL` 81 + `NO_CALL` 84 | 87.17% | **94.79%** | 89.23% | **160/168 (95.24%)** | 2/24 (8.33%) |
| + 한국어 HN + authoring matched | `CALL` 81 + `NO_CALL` 258 | **89.17%** | **94.79%** | **89.55%** | 159/168 (94.64%) | **1/24 (4.17%)** |

positive만 보강하면 HN-only에서 사라졌던 Tool 요청 대부분을 되살렸지만 일반
대화 오실행도 41.67%로 다시 높아졌다. 반면 같은 Tool별 `NO_CALL`을 함께 넣은
matched 조건은 오실행을 1건으로 유지하면서 Tool 요청 159건을 통과시켰다.
즉 이번 개선의 핵심은 positive 수 자체보다 **실행 요청과 실행하면 안 되는
유사 문장을 함께 학습한 것**이다.

HN 없는 matched 조건과 HN을 포함한 matched 조건은 Holdout 정답 수가
182/192로 같다. HN을 추가하면 오실행이 2건에서 1건으로 줄지만 Tool 누락은
8건에서 9건으로 늘었다. 대신 3i4K official test는 87.17%에서 89.17%로
올랐다. P0 안전성을 우선하면 HN 포함 조건이 더 적합한 탐색 후보지만, 두 조건
사이 우열을 확정할 표본은 아니다.

HN 포함 matched 조건의 PetAI Dev도 Gate Accuracy 93.75%, Macro-F1 87.81%,
Tool 요청 재현율 93.45%, NORMAL 오활성률 4.17%였다. Holdout의 남은 오류는
Tool 누락 9건과 오실행 1건이다. 누락은 `missing_parameter` 4건,
`create_timer` 3건, `list_alarms` 2건 등에 집중됐다. 유일한 오실행 문장은
제3자 습관을 말한 `아빠는 라면 끓일 때마다 4분 타이머를 켜 놓으세요.`였다.

이 결과는 확인적 성능이 아니다. 기존 Holdout은 이전 실험에서 이미 열렸고,
이번 데이터·코드 설계에도 사용됐다. authoring 중복 3건은 제거했지만 Dev와
Holdout 사이에도 동일 문장 8건이 있어 두 지표는 서로 독립적이지 않다. 따라서
현재 후보를 제품에 통합하지 않고, matched 구성과 안전 우선 선택 규칙을 잠근
뒤 새 미열람 Holdout에서 한 번 검증해야 한다.

### Matched 실행 및 재현 증거

- 실행 Git commit:
  `6f69d62df85e49b48b59f3e390b5ee58832bfd6c`
- 평가 입력 해시까지 기록한 최종 재현 Git commit:
  `5f93d74015fa7be42e3dab6a55fd3a7f05376031`
- authoring 원본: 168건, SHA-256
  `2591292dc333d80d8f4bbbef2c938a7eeab3796f6db1cd89ebbcdddfb1e9a962`
- authoring retained: `CALL` 81 / `NO_CALL` 84, exact Holdout overlap 3건 제외
- PetAI development embedding SHA-256:
  `d129f6818180b75cbafd9176a4a102890cbb2bc88070c34cbba6393c7f70b5e2`
- 한국어 HN embedding SHA-256:
  `ef175d130136c59b7776a0d0a69ef87d4f144f6ed7d095d5a141cb14d638c020`
- HN 포함 matched weights SHA-256:
  `75920fd469f092ec112ce2e0b13d66f86fefde00d0671a96c53989ed8578ee2b`
- HN 포함 matched Holdout predictions SHA-256:
  `b57cafeb5b6725e26a0c59bfa95f803929cdcf02a2ee990081907e52ecd7cc37`
- 동일 commit 반복 실행에서 metrics SHA-256
  `617c733097e816ec66211aa0ac36d7b3b7954f70ab62432ef760e2a9e9b599b6`와
  weights SHA-256이 모두 일치했다.
- 최종 재현 commit에서도 네 ablation의 metrics와 weights가 최초 실행과 모두
  일치했다.
- runtime: Python 3.12.13, scikit-learn 1.9.0, `ai-edge-litert` 2.1.3,
  Mac CPU
- `UNVERIFIED`: 새 미열람 Holdout, Core ML/LiteRT head 변환, Swift 통합,
  iPhone 지연시간·메모리와 실제 Tool E2E

## Prompt-only Gemma 회고 비교

2026-08-11에 현재 배포 정본인 Gemma 4 E2B IT를 별도 학습 없이 고정
프롬프트만 사용해 기존 Pilot Holdout 192건에서 실행했다. 같은 case ID와 같은
채점기로 Regex·Embedding 결과와 비교했다.

| 평가 | Exact match | Macro-F1 | Hamming loss | NORMAL 오활성률 |
| --- | ---: | ---: | ---: | ---: |
| Prompt-only Gemma 4 E2B IT | **95.31%** (183/192) | **97.46%** | **0.67%** | **9/24 (37.50%)** |
| Embedding `embedding-09` | 85.94% (165/192) | 92.44% | 2.01% | 11/24 (45.83%) |
| 고정 Regex 기준선 | 63.02% (121/192) | 73.94% | 5.28% | 11/24 (45.83%) |

Gemma는 실제 Tool 요청 168건을 모두 정확히 분류했다. 9개 오답은 모두
일반대화를 Tool로 실행하려 한 false positive였다. 오류는 기능 문의 3/4,
인용·제3자 발화 3/4, 희망·가정 2/4, 의미 경계 1/4에 집중됐다. 과거 언급과
부정 요청은 각각 4/4를 `NORMAL`로 판정했다.

| 실패 유형 | 오실행 | 대표 입력 | Gemma 출력 |
| --- | ---: | --- | --- |
| 기능 문의 | 3/4 | `내가 만든 알람 목록을 확인하는 기능도 지원해?` | `list_alarms` |
| 인용·제3자 발화 | 3/4 | `아빠는 라면 끓일 때마다 4분 타이머를 켜 놓으세요.` | `create_timer` |
| 희망·가정 | 2/4 | `정해 둔 시각에 스트레칭하라고 알려주면 좋겟다.` | `schedule_local_notification` |
| 의미 경계 | 1/4 | `“이번 주 일정이 꽉 찼다”라고 민지가 말했어.` | `get_calendar_events` |

전체 exact match는 Embedding보다 18건 높았지만, 안전 핵심인 NORMAL
오활성은 단 2건 감소했다. NORMAL 24건의 paired exact McNemar 검정도
Embedding 대비 `p=0.774`로 차이를 확인하기에 표본이 부족하다. 따라서
prompt-only Gemma는 Embedding-only보다 유망하지만 현재 상태로 실행 gate를
대체하지 않는다.

이 비교는 기존 Holdout 결과를 이미 확인한 뒤 프롬프트를 설계한 **회고
실험**이다. 새 후보 선택을 위한 확인적 결과가 아니며, 다음 판단은 hard
negative를 보강한 새 Dev에서 프롬프트를 잠근 뒤 열지 않은 Holdout으로 해야
한다.

### 출력과 실행 비용

- 형식 준수: 192/192 exact label, fallback 0건, 런타임 오류 0건
- Gemma 전체 응답 지연: 평균 1,455.0ms, 중앙값 1,446.2ms, p95 1,515.9ms
- 기존 Embedding query 추론 지연: 평균 88.7ms, 중앙값 87.8ms, p95 97.8ms
- Regex 지연: 기존 결과에 측정값이 없어 비교하지 않음

Gemma 지연은 warm 상태의 LiteRT-LM 비스트리밍 전체 응답 시간이고,
Embedding 값은 query embedding 추론만 측정했으므로 완전히 같은 범위의
end-to-end 수치는 아니다. 그래도 Gemma 호출은 평균 기준 약 16.4배 느렸다.
PetAI가 이미 같은 2,588,147,712-byte 대화 모델을 배포하므로 추가 모델 파일은
필요 없지만, 라우팅을 별도 생성 호출로 두면 매 발화에 이 비용이 추가된다.

### Gemma 실행 증거

- candidate: `gemma-e2b-prompt-router-retrospective-v1`
- 실행 Git commit: `14f349061733596cdefc784316674494daa28055`
- Holdout SHA-256:
  `0c1de17e1092e6562617868f787a11e409bb6c0472841ba3e778d801460a1bb3`
- model: `gemma-e2b-it`, revision
  `9262660a1676eed6d0c477ab1a86344430854664`
- model SHA-256:
  `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`
- prompt SHA-256:
  `9d7a42ba3b12b12dde75f79c5e555a39c0c84555b73ad57157d418de483925f6`
- config SHA-256:
  `07ad5902d0c8213839572818b290064dc4d2997606eafb857f31ac80f2690e7b`
- predictions SHA-256:
  `9dea9560796520f321255145409d923088d0920852034a2500af678582721016`
- result SHA-256:
  `45fb6b79792f7d8db5f1d798a38791b3cdcde90b51e2b518daed959b62b0f40b`
- manifest SHA-256:
  `1dc2860d2c8d695d22cfa392e5019e8a8988ec67dca6a0ed7442107d441530df`
- runtime: LiteRT-LM 0.13.1, CPU, macOS 26.5.1, Apple M5 Pro 64GB
- `UNVERIFIED`: iPhone TTFT·지연시간·메모리·발열·배터리

## 기존 Pilot 결정

Pilot Embedding 후보는 현재 Swift Regex 기준선보다 도구 분류 품질을 높였지만,
최우선 안전 지표인 NORMAL 오활성률은 개선하지 못했다. 따라서 이 후보는
제품에 통합하지 않는다. ToolRouteBench는 MVP P0로 계속하고, 새 데이터에서
안전 gate를 통과한 후보만 feature flag 뒤의 Swift 검증으로 넘긴다.

## 기존 봉인 Holdout 결과

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

## 3i4K 전체 PetAI 후보 마이닝

2026-08-11에 official test 중복을 제거한 3i4K train 43,521건 전체를 배포
정본 EmbeddingGemma로 임베딩했다. 기존 3i4K 발화 유형은 provenance로만
보존했고 `question/command → CALL` 약한 라벨은 사용하지 않았다.

| 산출물 | 건수 |
| --- | ---: |
| 전체 미라벨 풀 | 43,521 |
| 감사 후보 | 4,905 (11.27%) |
| 탈락 풀 | 38,616 |
| 탈락 감사 표본 | 700 |

후보는 도구별 Embedding Top-1,000, 기존 `embedding-09` 임계값보다 0.05
낮은 행, Swift 의미 보존 Regex 적중 행의 합집합이다. 하나의 문장이 여러 Tool
후보에 들어갈 수 있어 Tool ID 수는 후보 행 수보다 많다.

| 후보 Tool ID | 건수 |
| --- | ---: |
| `get_step_count` | 1,014 |
| `create_alarm` | 1,000 |
| `list_alarms` | 1,000 |
| `create_timer` | 1,000 |
| `schedule_local_notification` | 1,004 |
| `get_calendar_events` | 1,379 |
| `create_calendar_event` | 1,106 |

선택 근거는 Embedding Top-K 7,000개, 완화 임계값 3,054개, Regex 680개다.
후보 행 중 단일 Tool 후보는 3,198건이고 2개 이상 Tool 후보는 1,707건이다.
원본 발화 유형별 후보는 command 1,785, question 2,299, statement 330,
intonation-dependent 302, fragment 108, rhetorical question 45, rhetorical
command 36건이었다.

마이닝 결과는 라벨이 아니다. 실제로 `get_step_count` 최고 유사도 후보에
`오늘 가시거리가 얼마나 되니`가, `create_timer`의 Top-K 하단에
`최신곡 노래 틀어줘`가 포함됐다. 따라서 4,905건을 그대로 CALL로 학습하지
않고, 탈락 표본 700건과 함께 라우터 근거를 숨긴 두 독립 계약 판정 및 사람
표본 감사를 거친다.

### 전수 실행 증거

- 실행 Git commit:
  `8b01b8fdeb882c2c963402a75a97baa523b889a1`
- pool manifest SHA-256:
  `1caeb7d732fe368be963922e6569eddf49fb2f2f0bc3d88c7d3d975c1f4158a6`
- embedding output SHA-256:
  `2a87443723330563614277f8d948f886bc9f08bc7f5cef3664864f02ad1a8d04`
- embedding manifest SHA-256:
  `98a6fc50b3c77c76773a8e71defa106f84d268bb19c0338dc9fd147837ffdc4e`
- mining manifest SHA-256:
  `b602fff43d4dabce6bf6812455f1e4c895865a2ed3ea92fab4e6b0104587a53c`
- candidates SHA-256:
  `dd1ea8495f190293232079b7599eb16859c6731fea83122ef584c863f0b570fb`
- rejected audit sample SHA-256:
  `46a683029aab75a884ff79651cec3f61a1537486af4f2ae7302c99ee2d0a44f1`
- model SHA-256:
  `37115ef7bff76cd37dd86abe503ff511b1032bf85fc624a85c49c84899e92bc5`
- runtime: `ai-edge-litert` 2.1.3, CPU, 3,466.69초
- `UNVERIFIED`: 잠정 라벨 합의율, 탈락 표본의 실제 CALL 비율, 사람 감사,
  균형 학습 풀과 새 Holdout 성능

### 이중 독립 PetAI 계약 판정

마이닝 후보 4,905건과 탈락 표본 700건을 합친 5,605건을
`gpt-5.6-sol`, reasoning effort `medium`의 서로 다른 contract/blind 세션으로
판정했다. 두 프롬프트에는 라우터 점수·선택 Tool·3i4K 원본 발화 유형을 주지
않았다. 두 세션의 Tool 집합이 정확히 같고 둘 다 비모호인 행만 잠정 채택했다.

| 결과 | 건수 |
| --- | ---: |
| 잠정 합의 | 5,270 (94.02%) |
| 미합의·모호 | 335 (5.98%) |
| 합의 `CALL` | 2,018 |
| 합의 `NO_CALL` | 3,252 |

후보 partition에서는 `CALL` 2,013, `NO_CALL` 2,561건이 합의됐고 331건이
제외됐다. 탈락 감사 표본에서는 `CALL` 5, `NO_CALL` 691건이 합의됐고 4건이
제외됐다. 탈락 CALL 5건은 모두 일정 조회로, 예시는
`내일 오후 네시 미팅 장소가 어디니`와 `동아리 연합 엠티 가는 날을 알려라`다.

Tool 분포는 `get_calendar_events` 1,223, `create_calendar_event` 681,
`create_alarm` 55, `schedule_local_notification` 51, `list_alarms` 10,
`create_timer` 2건이며 `get_step_count`는 0건이다. 따라서 이 데이터는 한국어
실행 여부 gate를 확장하는 보조 풀로는 유용하지만, PetAI 7개 Tool ID 분류를
독립적으로 학습시키는 정본으로는 불충분하다.

잠정 균형 풀은 모든 CALL 2,018건을 유지하고 NO_CALL을 2,018건으로 줄인다.
NO_CALL은 후보 hard negative 1,614건과 탈락 표본 404건으로 구성한다. 이 풀은
커밋 `5a8dcf978cf7c7aaded77d712b532ec7cd37afbb`에서 생성했으며, 사람 승인
전이라 아직 train/calibration/Holdout으로 분리하지 않았다. 선택되지 않은 합의
NO_CALL 1,234건도 별도 파일로 보존했다.

#### 판정 실행 증거

- labeling Git commit:
  `cd721dcd6e501fb04edc490fadbd17e9fe04b0b4`
- labeling queue SHA-256:
  `f00fe9bf2d11bdd5432e0218105bc55554a17eb13cac64baa8cc18b6b1573e70`
- contract predictions SHA-256:
  `12b4d90786d5997959540273d14a832e073868a2e4d53c4416505d9aaa46bd7a`
- blind predictions SHA-256:
  `1ce88bd2e02478310a66b3b98894a4a839d73fa313a36403ce677dd6c2558b87`
- agreed labels SHA-256:
  `86f033887c9c9cdf4ef88ad78a196b8bf2f3afb649bf77cdf1a9c1c0b6d6c11c`
- unresolved SHA-256:
  `7b384e4f3eb90253c1e81ca506766c1b69e05dff0f247fccddd8fc0b3c20d551`
- balanced pool SHA-256:
  `0e55bbb9cc286ee319d242be46c40562e98d9bc4a1d2f19623788a047bca9cc2`
- balanced pool manifest SHA-256:
  `0467649f546f563c5972b48226455cbdea02191b69908df4a745d0e1258ac2bb`
- 고정 표본: 155건, agent 수동 검토에서 명백한 오라벨 0건. 사람 승인은
  여전히 `UNVERIFIED`다.

### 계약 라벨 MLP Head 학습과 회고 Holdout

사용자의 실험 진행 승인 후 균형 풀을 NFKC·공백/구두점 무시 기준으로
중복 제거했다. 사실상 같은 문장 11건과 클래스 재균형용 NO_CALL 1건을 제외해
4,024건을 만들었다. CALL/NO_CALL과 Tool 조합을 층화해 다음처럼 분리했다.

| split | CALL | NO_CALL | 합계 |
| --- | ---: | ---: | ---: |
| train | 1,610 | 1,610 | 3,220 |
| validation | 201 | 201 | 402 |
| test | 201 | 201 | 402 |

train에는 평가 세트와 겹치는 3건을 제거한 기존 PetAI authoring 165건을 더했다.
최종 학습 분포는 CALL 1,691, NO_CALL 1,694로 거의 균형이다. 768차원
EmbeddingGemma 벡터 위 64-unit MLP는 350 iteration에서 수렴했다. threshold는
Holdout이 아닌 PetAI dev macro F1로 선택했으며 값은 0.20이다.

| 평가 | Accuracy | Macro F1 | CALL precision | CALL recall | NO_CALL 오활성 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3i4K validation | 97.01% | 97.01% | 95.65% | 98.51% | 4.48% |
| 3i4K test | 95.27% | 95.27% | 92.52% | 98.51% | 7.96% |
| PetAI dev | 92.19% | 84.55% | 98.11% | 92.86% | 12.50% |
| PetAI Holdout 회고 | 93.23% | 86.21% | 98.14% | 94.05% | 12.50% |

PetAI Holdout의 Tool별 CALL recall은 다음과 같다. 각 Tool 표본은 24건이다.

| Tool | Recall | 누락 |
| --- | ---: | ---: |
| `create_alarm` | 100.00% | 0 |
| `create_calendar_event` | 95.83% | 1 |
| `create_timer` | 95.83% | 1 |
| `get_calendar_events` | 95.83% | 1 |
| `get_step_count` | 87.50% | 3 |
| `list_alarms` | 95.83% | 1 |
| `schedule_local_notification` | 87.50% | 3 |

3i4K 계약 라벨만 학습하고 threshold 0.65를 사용한 초기 모델은 PetAI 회고
Holdout accuracy 63.54%, 걸음 수 recall 0%, 타이머 recall 20.83%였다. 기존
PetAI authoring 165건을 추가하고 PetAI dev에서 보정하면서 각각 93.23%, 87.50%,
95.83%로 회복됐다. 이는 새 합성 증강 전에 기존 고밀도 PetAI 예시를 포함해야
한다는 근거다.

다만 직전 `ko-authoring-matched-final-v2`의 열린 Holdout accuracy 94.79%,
Macro F1 89.55%, 오활성률 4.17%를 넘지는 못했다. 새 모델의 오활성 3건은
타인의 타이머 습관, 알림 희망 표현, 이미 확인한 캘린더 진술이다. 따라서 이
결과는 새 제품 정본 승격이 아니라, 걸음 수와 타이머 hard negative/positive를
함께 보강해야 한다는 기준선이다.

#### 최종 실행 증거

- training Git commit:
  `829e21d165126feec9b985568da0dc28919ddb0e`
- dataset manifest SHA-256:
  `e095f9e7bbe58f78aba00a794efcb437dc54fbee83ec47d8e5d9fcbbb3dd4739`
- result SHA-256:
  `1b4b3295ef973133a2a0cac4ef17138bcf82ef5cf0a30db4d1b8cbdf9537d506`
- model weights SHA-256:
  `f83b8429775d5c68266e9ba906687551c9a36471bc543a507aac33c2189e141e`
- runtime: Python 3.12.13, NumPy 2.5.1, scikit-learn 1.9.0,
  Embedding source `ai-edge-litert` 2.1.3 CPU
- 상태: research-only, PetAI Holdout은 이미 열린 회고 평가

## MVP P0 다음 실험

1. 기존 Pilot 데이터와 열린 Holdout은 회귀 근거로만 보존한다.
2. matched 조건과 안전 우선 선택 규칙을 잠그고 새 calibration/holdout을
   만든다.
3. 새 train/calibration에서 `missing_parameter`, `create_timer`,
   `list_alarms` 누락을 matched pair로 보강한다.
4. 새 Holdout을 보기 전에 NORMAL 오활성률 상한, Regex 대비 개선 조건과
   도구 분류 비회귀 조건을 등록한다.
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
