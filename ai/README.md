# PetAI AI workspace

status:: active
last_reviewed:: 2026-08-11

`ai/`는 PetAI에 직접 필요한 온디바이스 모델·대화·메모리 연구를 재현하는
공간이다. 이 문서는 각 연구의 **연구 상태**, **제품 반영 상태**, **다음
의사결정**을 구분하는 저장소 수준의 인덱스이자 2026년 8~11월 연구
로드맵이다.

## 제품 경계

PetAI는 게임이 본체이고 AI는 표현 계층이다. 관계 수치, 보상, 해금, 미니게임
판정과 필수 진행은 결정론적 게임 코드가 소유하며 모델이 없어도 핵심 게임은
동작해야 한다. 대화·장기 기억·건강 정보와 네이티브 도구 처리는 기기 안에서
수행하고, 새 원격 전송 경로는 별도 동의·보관·삭제·실패 계약 없이는 추가하지
않는다.

따라서 연구 우선순위는 벤치마크 점수 자체보다 다음 순서를 따른다.

1. 설치한 앱에서 모델을 안정적으로 받고 로드할 수 있는가?
2. iPhone에서 대화·기억·도구가 크래시 없이 안전하게 동작하는가?
3. 현재 제품 품질의 병목을 재현 가능한 평가로 분리할 수 있는가?
4. 그 병목을 줄이는 가장 작은 변경이 실제 제품 조건에서도 유효한가?

## Source of truth

| 대상 | 정본 |
| --- | --- |
| 제품 방향과 MVP 범위 | [`docs/product/petai_product_strategy_and_mvp_spec.md`](../docs/product/petai_product_strategy_and_mvp_spec.md) |
| 전체 기능 지도와 AI 책임 경계 | [`docs/product/final_product_feature_map.md`](../docs/product/final_product_feature_map.md) |
| Unity·계약·플랫폼 경계 | 루트 [`README.md`](../README.md), [`contracts/README.md`](../contracts/README.md), [`unity/README.md`](../unity/README.md) |
| 배포 모델·파일·해시 | [`models/runtime-models.json`](models/runtime-models.json) |
| 실제 제품 동작 | `ios/EdgeLLM/`, `ios/UnityBridge/`, `unity/Assets/`의 현재 코드와 해당 테스트 |
| 연구 계약과 결과 | 각 연구 폴더의 `README.md`, `SPEC.md`, `RESULTS.md`, manifest |

연구 보고서의 점수는 그 manifest에 기록된 데이터·모델·런타임 조건에서만
유효하다. Mac 품질 실험은 iPhone의 지연시간, 메모리, 발열, 배터리 또는 OOM
안전성을 증명하지 않는다. 연구 문서와 현재 제품 코드가 다르면 제품 동작의
정본은 코드이고, 차이는 연구 상태표에 명시한다.

## 상태 정의

- **active**: 현재 질문과 다음 의사결정이 정해져 있어 작업 중인 연구
- **frozen**: 현재 선택 근거를 재현할 입력·결과가 동결된 연구
- **exploratory**: 방향성만 확인한 소규모 실험으로 일반화 근거가 부족한 연구
- **paused**: 결과는 보존하지만 현재 제품 병목이 아니어서 후순위인 연구
- **infrastructure**: 평가 대상이 아니라 모델·도구의 실행 정본
- **integrated**: 일부 또는 전부가 제품 코드에 반영됨
- **not integrated**: 연구 결과가 제품 경로에는 들어가지 않음

## 연구 포트폴리오

| 영역 | 확인한 것 | 연구 상태 | 제품 상태 | 다음 의사결정 |
| --- | --- | --- | --- | --- |
| [`models/`](models/) | Gemma 4 E2B IT, EmbeddingGemma 300M, SentencePiece의 버전·해시·Apple asset pack | infrastructure | integrated | MVP 동안 모델 버전과 pack ID를 동결하고 다운로드 생명주기만 검증 |
| [`memory-classifier/`](memory-classifier/) | P/E 축 저장 판정, MLP 기준선, Gemma 메모리 헤더 실험 | frozen historical baseline | `save(P=X,E=Y)`와 fail-closed gate만 integrated | 새 프롬프트 변경이 있을 때만 별도 holdout으로 회귀 평가. MLP 폴백은 제품에 넣지 않음 |
| [`mrbench-custom/`](mrbench-custom/) | 엘레나 지식 경계와 장면별 페르소나 라우팅 | frozen best-found MVP candidate, not gold | core·scene card를 generic `RoutedPersona` 경로로 integrated | 현재 1회 생성 경로의 iPhone 지연·메모리·발열과 알려진 경계 실패를 검증 |
| [`facetroutebench/`](facetroutebench/) | Gemma 장면 라우터와 EmbeddingGemma 유사도 라우터를 비교하는 20-route 계약과 route별 threshold 연구 | v2 회고 실험 종료, v3 확인 실험 active | v2 Embedding Router candidate integrated | 새 v3 Dev/Frozen 확인과 iPhone 지연·메모리·발열 검증 |
| [`toolroutebench/`](toolroutebench/) | 7개 네이티브 Tool의 Regex·Embedding·prompt-only Gemma 라우팅 비교 | matched MLP 회고 SOTA와 `embedding-09` 2단계 후보 구현, 새 Holdout 연구 active | provisional iOS integration | iPhone E2E와 새 calibration/holdout에서 안전성 확인 |
| [`needle2-argument-canary/`](needle2-argument-canary/) | Router가 Tool 하나를 선택한 뒤 Needle 2와 Gemma E2B의 한국어 인자 제안 비교 | exploratory zero-shot canary complete | not integrated | Needle은 한국어 PetAI fine-tune과 새 미열람 Holdout을 통과하기 전 제품 통합하지 않음 |
| [`edgemembench/`](edgemembench/) | A 저장, B 검색, C 시간 충돌, D 기권의 494문항과 Dense/temporal/cohort 진단 | v0 benchmark frozen, resolver research paused | Dense cosine 검색만 integrated | MVP 뒤 구조화 상태·valid time·결정론적 reducer 연구의 기준선으로 사용 |
| [`profile-memory-kv/`](profile-memory-kv/) | 닫힌 key 하나와 value 또는 `null`을 출력하는 24문항 smoke | exploratory, paused | not integrated | 새 holdout에서 기권 성능을 먼저 확인한 뒤 structured proposal 연구 지속 여부 결정 |

### 현재 코드와 연구 문서의 중요한 차이

- 현재 Swift 메모리 헤더는 canonical `save(P=0|1,E=0|1)`만 사용하며 형식
  오류 시 저장하지 않는다. `memory-classifier/README.md`의 legacy
  `save(P)` 복구와 MLP 폴백은 과거 연구 하네스 설명이지 현재 제품 정책이
  아니다.
- 현재 앱의 `DenseMemoryRetriever`는 cosine 유사도 내림차순, 동점 시 최신
  순서와 동일 텍스트 제거를 수행한다. 제품 기본값은 cosine `0.3` 이상
  **Top-10**이며, 회수 문장은 UTF-8 byte 기반 10,000-unit 예산 안에서
  프롬프트에 들어간다. EdgeMemBench의 Dense Top-20은 후보 검색·오류 분석용
  벤치 설정이지 제품 기본값이 아니다.
- 현재 일반 대화의 Scene Route 기본 경로는 동일한 EmbeddingGemma 인스턴스를
  재사용하는 19-route cosine router다. 합격한 전문 route가 없거나 임베딩·라우팅
  오류가 나면 `GENERAL`로 닫히며 Legacy Gemma Router로 자동 폴백하지 않는다.
  이 문서 작성 시점의 통합 브랜치에는 수동 비교·롤백 경로만 남아 있고,
  완전 삭제는 별도 PR #114에서 추적한다.
- ToolRouteBench의 제품 경로는 HN+PetAI matched MLP가 `CALL/NO_CALL`을 먼저
  판정하고, `CALL`만 Pilot `embedding-09`에 전달하는 2단계 구조다. Regex는
  고정 연구 기준선으로만 남고 prompt-only Gemma는 제품 라우팅에 쓰지 않는다.
  MLP 회고 Holdout의 NORMAL 오활성률은 4.17%였지만 이미 본 Holdout이므로 새
  미열람 평가와 iPhone E2E 전까지 provisional 통합으로 취급한다.
- EdgeMemBench의 global timestamp reranking은 Hit@1을 33.33%에서 40.58%로
  올렸지만 2건을 악화시켰다. cohort oracle과 실제 정책의 큰 격차는 단순
  시간 가중치보다 `answer-bearing state`와 valid time 표현이 병목임을
  보여준다. 이 resolver는 제품에 반영되지 않았다.
- MRBench-Custom의 선택 후보는 Mac GPU에서 재현된 MVP 근거다. 고정 60문항
  라우팅과 응답 재현, 평균 776ms는 iPhone end-to-end 성능을 뜻하지 않는다.
  연구 V14의 생성형 boundary/scene router 전체를 그대로 제품에 넣은 것도
  아니다. 현재 제품은 Boundary Router를 제거하고 Embedding Scene Router와
  최종 Gemma 생성 1회만 사용하므로 별도 제품 조건 회귀가 필요하다.
- Profile KV의 79.17%는 같은 24문항을 재사용한 개발 결과다. 질문, 제3자
  발화와 일회성 사건을 현재 사용자 프로필로 오인하는 문제가 남아 있다.

## 런타임 튜닝 연구 계획

제품 기본값의 정본은 `SLMConfiguration.production`이며 호출부에 숫자를
복제하지 않는다. 현재 메모리는 Top-10, 최소 cosine `0.3`, 10,000-unit
프롬프트 예산을 사용하고 생성 출력은 최대 4,096토큰으로 제한한다. 이는 MVP
기본값이지 최종 연구 결론이 아니다.

1. 같은 EdgeMemBench 문항으로 Top-3, Top-5, Top-10을 비교하고 검색 품질,
   실제 prefill token, TTFT와 전체 지연시간을 함께 기록한다.
2. 현재 10K 예산은 정확한 token 수가 아니라 결정론적 UTF-8 byte proxy다.
   runtime이 생성 전 tokenization을 노출하면 Gemma tokenizer의 정확한 token
   budget으로 교체한다.
3. 임시 `0.3` 유사도 하한은 별도 calibration split에서 보정한다. 같은 test로
   threshold를 고르고 성능을 주장하지 않으며, v0에서는 sweep만 보고한다.
4. reranker를 도입할 때는 하나의 Top-K 의미를 조용히 바꾸지 않고 더 큰
   `denseCandidateLimit`과 더 작은 `promptMemoryLimit`으로 분리한다.

## MVP 연구 — 2026년 8월 31일까지

8월의 목표는 새로운 메모리 아키텍처를 완성하는 것이 아니라, 현재 통합된
AI 경로가 MVP 앱에서 안전하게 작동한다는 증거를 만드는 것이다. 우선순위는
P0, P1 순이며 P0가 막혀 있으면 P1 연구 규모를 늘리지 않는다.

### P0-1. 모델 다운로드 생명주기와 최초 실행

정본은
[`docs/ai/runtime_model_download_lifecycle.md`](../docs/ai/runtime_model_download_lifecycle.md)다.

- 신규 설치에서 Memory pack과 Language pack을 순차로 내려받고 각각 검증한다.
- 93% 정체, 화면 잠금, background/foreground, 앱 재실행, 수동 중단·재시도,
  저장공간 부족과 손상 복구를 실제 TestFlight iPhone에서 확인한다.
- 완료 pack 재사용, 중복 요청 방지, 모델 없이 게임 이용, 채팅 진입 시점의
  지연 로드를 확인한다.
- 실행한 Build, 기기, iOS, 네트워크, 남은 저장공간과 로컬 진단 로그를 함께
  남긴다.

**종료 조건:** 신규 설치와 중단 복구 시나리오에서 모델 상태가 실제 파일
상태와 일치하고, 사용자가 앱을 재설치하지 않아도 실패에서 복구할 수 있다.

### P0-2. iPhone 런타임 자원 기준선

정확한 배포 `.litertlm`과 현재 커스텀 LiteRT-LM runtime으로 다음을 측정한다.

- cold/warm 모델 로드 시간과 첫 토큰 지연시간
- 답변 완료 지연시간, peak memory와 OOM 여부
- 10회 이상 연속 대화와 15분 사용 중 thermal state 변화
- 대화 취소·재시도, 앱 전환·화면 잠금 뒤 복귀
- reasoning off/on이 필요한 경로를 분리한 토큰 수와 지연시간

Mac 수치는 품질 회귀와 빠른 비교에만 사용한다. 기기 합격 임계값은 첫 기준선
측정 전에 별도 QA 계약으로 고정하고, 측정 후 유리하게 바꾸지 않는다.

**종료 조건:** 최소 지원 iPhone 범위를 명시하고, 그 범위에서 모델 로드와
반복 대화가 크래시 없이 완료되며 비교 가능한 성능 기록이 남는다.

### P0-3. 통합 대화 안전성 회귀

현재 제품 경로 전체를 한 번에 검증한다.

```text
Unity 입력
  -> Regex-first native tool route
     -> tool: Gemma parameter proposal -> Swift 검증 -> 사용자 확인 -> native API
     -> normal: memory query embedding -> Dense Top-10
                + classification embedding -> Embedding Scene Router
                -> Routed Persona prompt
                -> Gemma 응답 + save(P=X,E=Y)
                -> 화면 출력 / 최대 1회 SQLite commit
```

- Scene Router의 낮은 점수·오류는 `GENERAL`로 닫히고 Legacy Gemma Router를
  자동 호출하지 않는다. 내부 route·prompt·memory header는 화면에 노출되지
  않아야 한다.
- 헤더만 있고 답변이 없으면 답변 재시도는 정확히 한 번, 그마저 실패하면
  저장하지 않아야 한다.
- `P=0,E=0`과 malformed/missing header는 저장하지 않고 P/E/B는 요청당 최대
  한 번만 저장해야 한다.
- 재실행 뒤 기억 회수, 제3자·가정·일회성 발화의 과저장, 도구 결과의 장기
  기억 유입을 확인한다.
- MRBench-Custom의 고정 60문항과 18문항 holdout은 프롬프트·라우터가 바뀔
  때만 회귀 실행하고, iPhone에서는 대표 지식 경계·scene 표본을 확인한다.

**종료 조건:** 제어 토큰 누출 0건, 중복 commit 0건, fail-open 경로 0건이며
알려진 모델 품질 실패와 코드 계약 실패가 분리되어 기록된다.

### P0-4. 네이티브 도구의 계약·권한·생명주기

현재 구현된 7개 도구만 동결 범위로 검증한다.
이는 HealthKit을 게임 MVP의 필수 기능으로 승격하는 연구가 아니라, 이미
통합된 선택적 기술 PoC가 게임과 개인정보 경계를 깨뜨리지 않는지 안정화하는
작업이다.

- `get_step_count`
- `create_alarm`, `list_alarms`, `create_timer`
- `schedule_local_notification`
- `get_calendar_events`, `create_calendar_event`

Mac에서는 한국어 Regex route, hard negative, 복수 도구 conflict, Gemma JSON
proposal, 날짜·숫자 범위와 parser fail-closed를 작은 고정 평가셋으로 검사한다.
iPhone에서는 확인 UI의 수정·승인·취소, 최초 권한 허용·거부, 앱 종료 뒤
알람·타이머·알림, HealthKit·EventKit 데이터 없음과 오류를 확인한다.

**종료 조건:** 사용자 확인 전 실행 0건, 같은 request의 중복 실행 0건,
실패를 성공으로 표시한 경우 0건, 도구 결과의 EdgeMem 저장 0건이다. 새로운
도구나 건강 지표 확장은 MVP 연구에 포함하지 않는다.

### P0-5. ToolRouteBench MVP 안전 라우터

2026-08-08 Pilot은 192건 Dev에서 선택한 Embedding 후보 하나를 봉인 Holdout
192건에서 한 번 평가했다. Embedding 후보는 exact match 85.94%, Macro-F1
92.44%로 Regex 기준선의 63.02%, 73.94%보다 높았지만, 핵심 안전 지표인
NORMAL 오활성률은 두 방식 모두 11/24(45.83%)였다. 분류 품질 개선만으로는
제품 Router 교체 근거가 되지 않는다. 기존의 Regex 대비 비열등 gate는
충족했지만 절대 오활성률이 높고 제품용 상한도 사전 등록되지 않았으므로,
Pilot 후보는 제품 준비 완료로 판정하지 않는다. 세부 근거는
[`toolroutebench/RESULTS.md`](toolroutebench/RESULTS.md)에 고정한다.

- 현재 Regex Router를 제품 기준선으로 유지하고, 새 calibration과 봉인
  Holdout에는 일반 대화·부정·가정·도메인 단어만 있는 hard negative를
  보강한다.
- 새 Holdout을 열기 전에 NORMAL 오활성률 상한, Regex 대비 개선 조건과
  도구 분류 비회귀 조건을 등록한다.
- actionability gate, positive-normal margin, multi-tool conflict margin과
  Regex veto를 Dev에서 비교하고 후보 하나만 잠근다.
- 안전 제약을 통과한 경우에만 Swift에 feature flag로 이식하고 Python과
  판정 일치성을 확인한다. 권한·확인·취소·중복 실행 방지는 P0-4와 함께
  iPhone에서 검증한다.

**종료 조건:** 새 봉인 Holdout에서 NORMAL 오활성률이 고정 Regex 기준선보다
낮고 사전 등록한 안전 상한을 통과하며, 도구 분류 품질이 사전 등록한
비회귀 조건을 만족한다. 충돌·미지원·불명확 요청은 fail-closed여야 하고,
Swift 판정 일치와 iPhone E2E 증거가 없으면 MVP 완료로 표시하지 않는다.

### P1-1. 현재 EdgeMem 기준선 보존

- 저장 판단은 현재 wrapped-axis gate를 유지한다.
- 검색은 현재 제품의 Dense Top-10, 최소 cosine `0.3`을 기준으로
  재실행·회수·기권 사례를
  회귀 검사한다.
- EdgeMemBench v0는 A와 B-D를 분리하고, B-D에서 admission을 우회하는 현재
  계약을 유지한다.
- C의 timestamp, cohort resolver와 D의 운영 threshold는 v0 test에서
  튜닝하거나 제품에 병합하지 않는다.

**종료 조건:** MVP 대화에서 필요한 저장·재실행 회수 경로가 동작하고, 남은
최신성·기권 오류가 9월 이후 연구 입력으로 재현 가능하게 보존된다.

### P1-2. Embedding Scene Router 통합 후 검증

FacetRouteBench v2 회고 결과로 선택한 route별 threshold 후보가 제품 기본
Scene Router에 통합됐다. 다음 단계는 같은 데이터를 다시 튜닝하는 것이 아니라
통합 회귀와 아직 열지 않은 v3 확인 실험이다.

- v2 artifact와 Swift 리소스의 route ID, prototype, threshold, SHA-256 동등성을
  자동 검사한다.
- malformed resource, 임베딩 실패, 낮은 점수는 모두 `GENERAL`로 닫히고
  Legacy Gemma Router가 자동 실행되지 않는지 확인한다.
- v3 Dev에서 threshold 전략을 다시 선택하고 v3 Frozen을 한 번만 열어
  Macro-F1, `GENERAL` recall과 전문 카드 오활성화율을 보고한다.
- 실제 iPhone에서 router latency, 전체 TTFT, 메모리와 발열을 측정한다.

**종료 조건:** 새 Frozen에서 기준선 대비 허용 가능한 품질을 유지하고,
기기에서 생성형 Router를 제거한 지연시간 이득이 재현된다. 그렇지 않으면
Embedding Router를 최종 해법으로 표현하지 않는다.

### 8월 비목표

- Profile KV 또는 temporal reducer의 제품 병합
- FacetRouteBench v3 데이터 제작·실행을 P0 실기기 검증보다 먼저 수행
- 새 MLP 학습 또는 현재 Swift 경로의 조용한 MLP 폴백
- EdgeMemBench v0에서 운영 similarity threshold 선택
- 새 모델·양자화·asset-pack 교체
- full-vocabulary logits 저장, adaptive reasoning 또는 multi-memory
  composition 구현
- HealthKit 지표와 네이티브 도구 종류 확대

## MVP 이후 연구 — 2026년 9월~11월

아래 순서는 앞 단계의 결과가 다음 단계의 입력이 되도록 배치했다. 실험 하나는
한 번에 하나의 제품 의사결정만 답해야 하며, 선행 gate를 통과하지 못한 연구는
규모를 키우지 않는다.

### 9월: 라우팅·평가 체계 동결

1. **ToolRouteBench P0 통과 후보의 후속 확장**
   - MVP P0-5의 안전 gate와 iPhone E2E를 통과한 후보가 있을 때만 시작한다.
   - Pilot과 MVP 봉인셋은 다시 튜닝하지 않고 회귀 기준으로 보존한다.
   - 새 도구·표현·오타 범위를 별도 Dev/Holdout으로 확장하고, route 품질은
     Gemma parameter proposal의 field exact/schema pass와 분리해 보고한다.
   - Regex와 Embedding이 다를 때의 중재 정책, Swift validator와 사용자 확인은
     계속 명시적 계약으로 유지한다.

2. **FacetRouteBench v3 확인 실험**
   - v2의 제품 통합 사실과 v3의 아직 검증되지 않은 연구 상태를 분리한다.
   - 새 Dev에서 representation과 route별 threshold 전략을 선택하고, 잠근 후보
     하나만 새 Frozen에서 평가한다.
   - Mac 품질·router latency 뒤 대표 표본을 iPhone에서 측정한다.
   - 최종 결정은 Embedding Router 유지·수정·롤백 중 하나이며, 데이터 생성
     자체가 목표가 아니다.

3. **EdgeMemBench 평가 입력 보강**
   - v0 test와 분리된 calibration split 및 새로운 한국어 holdout을 만든다.
   - D의 similarity threshold는 calibration에서만 선택하고 holdout에서 한 번
     검증한다.
   - C는 `occurred_at`과 문장 속 valid time을 분리해 reader가 시간을 볼 수
     없는 표현 결손과 retrieval 순위 실패를 따로 기록한다.

### 10월: 구조화 기억과 결정론적 상태 해소

1. **닫힌 Profile KV 도메인부터 재검증**
   - 사용자 본인, 현재 사실, 지속성의 세 gate를 계약으로 유지한다.
   - 질문, 제3자, 인용, 희망·계획, 부정·변경, 일회성 사건을 포함한 새
     holdout을 만든다.
   - key 정확도보다 `null` 기권과 잘못된 영구 저장 비용을 우선 지표로 둔다.

2. **append-only observation과 proposal 분리**
   - 원문 `MemoryObservation`은 수정하지 않는다.
   - Gemma/parser 출력은 확정 사실이 아니라 `StructuredProposal(key, value,
     valid-time hint, source observation)`로만 기록한다.
   - 모델은 SQLite의 current state를 직접 덮어쓰지 못한다.

3. **결정론적 reducer 실험**
   - 같은 key의 새 값, 과거 회상, 단순 재진술, 공존 가능한 값과 사건을
     구분한다.
   - `recorded_at`과 `valid_time`을 분리하고 현재 질문, 과거 질문, 전환 질문에
     맞는 version view를 만든다.
   - 충돌 해소, source 추적, rollback과 중복 제거를 코드가 담당한다.
   - 먼저 shadow mode에서 기존 Dense 답변과 비교하고, holdout 개선과
     회귀가 확인된 뒤 feature flag 아래 제품 후보로 올린다.

4. **사용자 통제 설계**
   - 기억 보기·수정·삭제와 캐릭터별 전체 초기화를 제품 계약으로 만든다.
   - 건강 정보와 도구 결과가 기억으로 유입되지 않는지 계속 분리 검증한다.

### 11월: 고난도 기억·추론 최적화

1. **EdgeMemBench v1**
   - A-D를 새 holdout과 human-reviewed evidence로 재검증한다.
   - retrieval-only, reader-oracle, end-to-end를 분리해 실패 원인을 보고한다.
   - current/competing/context, answer-bearing version과 valid-time contract를
     scorer에 고정한다.

2. **E: multi-memory composition**
   - A-D가 안정된 뒤에만 두 개 이상의 기억을 조합해야 답할 수 있는 작은
     평가셋을 추가한다.
   - 검색 실패, 조합 실패와 모델 환각을 별도 지표로 분리한다.

3. **F: persona-level personalization**
   - MVP 이후 고도화 항목이다. 사용자 기억이 캐릭터 말투와 행동 선택에
     일관되게 반영되는지를 보되, 게임 상태와 관계 수치를 모델이 결정하게
     하지 않는다.
   - 11월에 계약과 소규모 pilot까지만 수행하고, 근거가 약하면 이후로 미룬다.

4. **Adaptive reasoning과 runtime telemetry**
   - reasoning off를 기본 기준선으로 두고, on이 실제로 이긴 태스크에만
     선택적으로 적용한다.
   - 현재 top-K logits telemetry로 반복·혼란·thinking budget 소진 신호를
     진단한 뒤 early stop 또는 answer-boundary 삽입을 offline benchmark에서
     비교한다.
   - raw full-vocabulary logits와 대화 내용을 제품 DB에 저장하지 않는다.
   - 정확도 이득뿐 아니라 iPhone 지연·메모리·배터리 overhead를 함께 보고,
     이득이 없는 경로는 reasoning off로 유지한다.

5. **모델 교체 연구는 마지막에 수행**
   - Gemma E4B, 새 양자화 또는 다른 SLM은 같은 frozen benchmark와 기기 측정
     계약이 준비된 뒤 비교한다.
   - 모델 크기 증가가 라우팅·기억·도구의 실제 실패를 줄이지 못하면 배포
     후보로 올리지 않는다.

6. **SLM 가드레일 연구**
   - MVP 이후 별도 안전성 평가셋과 실패 계약을 먼저 정의한 뒤, PetAI의 소형
     온디바이스 모델에 맞는 가드레일 방식을 비교한다.

## 연구 운영 규칙

1. 새 연구를 시작할 때 질문, 제품 의사결정, 기준선, 데이터 split, 지표,
   종료·중단 조건을 먼저 쓴다.
2. prompt와 threshold는 Dev/calibration에서만 바꾸고 Frozen/test/holdout은
   최종 후보에 한 번 사용한다.
3. Mac에서는 전체 품질과 빠른 latency 비교를 수행하고, iPhone에서는 물리
   자원과 end-to-end 동작만 최종 판정한다.
4. reasoning on/off, 모델, 양자화, runtime, backend, prompt와 데이터 SHA-256을
   run manifest에 기록한다.
5. LLM judge의 독립 절대 점수만으로 후보를 선택하지 않는다. 가능한 경우
   정답 계약, blinded pairwise 반복과 사람 오류 검토를 사용한다.
6. 통합 전에는 current product baseline과 후보를 같은 입력으로 비교하고,
   알려진 회귀와 fallback을 문서화한다.
7. 동시에 크게 확장하는 active 연구는 최대 두 개로 제한한다. P0 실기기
   blocker가 있으면 새 데이터 생성보다 blocker 재현과 해결을 우선한다.

## 저장 정책

Git에 커밋한다.

- 평가 runner와 결정론적 데이터 준비·검증 스크립트
- prompt, schema, manifest, 테스트와 작은 frozen 데이터셋
- 의사결정에 필요한 compact 결과와 재현 명령

Git에 커밋하지 않는다.

- 모델·tokenizer 가중치와 provisioning/signing 자료
- 가상환경, tool cache와 내려받은 upstream 원본 데이터
- 추출 embedding, checkpoint, 원시 반복 로그와 대용량 profile

생성·다운로드 파일은 각 연구의 Git-ignored `.artifacts/` 아래에 둔다. 모델
경로는 실행 시 명시하고, 커밋된 manifest에는 파일을 복사하지 않고 식별자와
SHA-256만 기록한다.
