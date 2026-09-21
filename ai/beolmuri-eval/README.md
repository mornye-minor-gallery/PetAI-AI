# Beolmuri Eval

status:: active

캐릭터를 다른 이름으로 불렀을 때 이름을 유지하는지 평가하는 실험 CLI다.
페르소나 지시, 출력 해석과 재시도 판단은 제품의 `EdgeLLM` Swift 코드를
실행한다. Python은 실행 관리, LiteRT-LM 연결, Codex CLI 채점과 수치 집계를
담당한다. Unity를 실행하거나 제품의 대화 로직을 Python으로 재작성하지 않는다.

## 공용 프롬프트 조립

앱과 평가 워커는 `ios/EdgeLLM/Sources/EdgeLLM/Dialogue`의
`DialoguePromptComposer.prepare`를 호출한다. 입력은 캐릭터 자료·프로필·이력·검색 기억·현재 발화이며,
`DialoguePromptPolicy`가 기존 페르소나 설정과 이름 지시 배치를 결정한다.
`system`, `before-current`, `after-current` 모두 같은 Swift 구현을 사용한다.
워커는 고정 자료를 공급하며 완성된 문자열을 잘라 이름 지시를 삽입하지 않는다.

`prepare` 결과의 `prompt_trace`에는 실제 시스템·사용자 항목 순서, 입력 바이트 수,
기억별 포함·제외 이유가 들어간다. 기본 YAML은 아래 토큰 예산을 사용한다.
`prompt_budget`이 없는 기존 연구 YAML은 UTF-8 바이트 예산으로 재현한다.
실제 이력 유지·기억 검색·도구 실행·응답 저장은 조립기가 수행하지 않는다.

캐릭터 원문은 엔진에 내장하지 않는다. 평가 YAML의 조건에 외부 콘텐츠를 지정한다.

```yaml
variants:
  daily:
    includePersona: true
    content:
      character: /private-content/characters/sample.yaml
      situation: /private-content/situations/daily.yaml
```

하네스는 앱용 변환기와 같은 함수를 사용하고, 조립은 Swift `DialogueContent`와
Composer에 맡긴다. 원본 YAML 두 개를 실행 입력에 복사하고 실제 콘텐츠를 manifest에
기록한다. 데이터셋의 `character_name`은 콘텐츠의 `name`과 같아야 한다.
`examples: []`이면 예시를 넣지 않는다. 직접 작성한 `personaCore`도 사용할 수 있지만
`content`와 동시에 지정하지 않는다. 캐릭터 없이 이름 규칙만 검사할 때는
`includePersona: false`를 명시한다. 기존 연구 YAML이 과거 콘텐츠를 자동 복원하지 않는다.

단위·통합 테스트는 제품 스토리와 무관한 명시적 검사 자료를 주입한다. 과거
프롬프트와 결과의 재현은 별도 보관된 당시 코드·자료에서 수행한다.

## 실제 토큰 기반 입력 준비

기본 `configs/name-identity.yaml`의 초기 설정:

```yaml
runtime:
  max_num_tokens: 8096
prompt_budget:
  memory_tokens: 2048
  output_tokens: 1024
```

기억 구역은 헤더까지 포함해 최대 2,048토큰이며, 전체 입력 최대 7,072 안에
포함된다. 현재 발화·이력·노트 등 모든 입력과 네이티브 템플릿을 합쳐 확인하고
출력 1,024토큰을 확보하지 못하면 오류로 중단한다. 품질 튜닝 전 시작값이다.
`runtime.max_num_tokens`를 명시해야 하며 출력 예약량은 실제 생성 상한에도 적용한다.

Swift의 공용 Composer가 기억을 선택한다. Python `prompt_prepare`는 Swift 워커의
측정 요청만 네이티브 토크나이저로 전달한다. 최종 입력 측정은 생성과 같은 thinking
설정의 임시 conversation을 사용한다. 실패하면 바이트 계산으로 대체하지 않는다.
재시도는 현재 KV까지 포함해 출력 공간을 다시 검사한다.

결과의 `input.prompt_trace.tokenBudget`에 전체 입력·기억 사용량·출력 예약량·남은
문맥 공간을 저장한다. `sections`에는 캐릭터·장면·프로필·이력·기억·현재 발화·노트
등의 독립 토큰 수가 있다. 이 값을 단순 합산해 최종 입력 토큰 수로 해석하지 않는다.
`measure-context` 결과에도 같은 trace를 포함한다. 본문은 기존 prepared 결과로 확인한다.

기존 실험 YAML의 예산과 출력 상한은 유지한다. `prompt_budget`을 추가하면 새 토큰
선택 경로가 되므로 새 run으로 시작해야 한다. 서로 다른 예산은 manifest와 비교 결과의
`differences`에 표시한다. 비교가 가능하다는 사실은 동일 조건의 실험이라는 뜻이 아니다.


## 실행 범위

기본 이름 데이터는 독립 단일 턴이며, 시나리오 데이터는 여러 턴을 이어서 실행한다.
GENERAL 장면은 고정하고 대화 이력·기억 검색 결과는 설정 또는 턴별 고정 자료로 공급한다.
장면 라우터, EdgeMem 검색·저장, OS 도구 실행과 Unity UI의 통합 평가는 아니다.
실험 설정은 평가 실행부에서 선택하며 제품 설정을 덮어쓰지 않는다.
제품은 개선된 이름 정정 규칙을 기본으로 사용하고, 평가의 각 조건은 YAML에 명시한다. 평가 실행 파일은 앱의 release target에 포함하지 않는다.

Gemma는 제품 모델 레지스트리의 `.litertlm` 파일을 GPU에서 실행한다.
macOS에서는 WebGPU를 통해 Metal을 사용하며, GPU 초기화 실패는 오류로 보고한다.
일반 `doctor`의 GPU 표시는 설정값이며, 실제 생성 검증은 `doctor --probe`로 수행한다.
Mac 어댑터는 `litert-lm==0.13.1`을 고정하며 모바일의 0.14.0 fork와 버전이
다르다. Mac의 결과를 iPhone 런타임·메모리·발열 검증으로 해석하지 않는다.
생성 설정은 Swift의 `SLMConfiguration.production`에서 받는다. 반복 실행의
시드는 `run.seed`(기본 0), 표본의 `pair_id`, 반복 번호, 턴 ID로 결정한다.
World Info와 생성 시드는 분리하며, World Info는 앱과 같은 Swift 규칙으로 누적
메시지 수만큼 진행한다. 표본 순서를 바꿔도 같은 표본의 시드는 유지된다.
GPU의 비트 단위 재현성은 주장하지 않는다. 추측 디코딩은 끄고 KV 용량은 모델 기본값을 사용한다.

## 설치와 환경 점검

저장소 루트에서 실행한다. Swift 6.3 이상, Python 3.12 이상, 로그인된 Codex
CLI와 별도 LiteRT-LM Python 환경이 필요하다.

```zsh
uv tool install --editable ai/beolmuri-eval
beolmuri-eval build
beolmuri-eval doctor
beolmuri-eval doctor --probe
```

`doctor`는 파일 해시, Swift 빌드 상태, CLI 버전과 네이티브 라이브러리 로드를
확인한다. `--probe`는 Gemma의 짧은 생성과 Luna의 실제 채점을 추가한다.
기본 출력은 초록 체크·노란 주의·빨간 실패로 구분하는 터미널 화면이다.
전체 경로와 해시 등 구조화 정보는 `--json`으로 확인한다. 파이프 출력과
`NO_COLOR` 환경에서는 색상 없이 표시한다.
모델 다운로드나 서버·상주 프로세스 설치를 자동으로 수행하지 않는다.
LiteRT-LM CLI가 uv tool로 설치됐다면 같은 환경의 Python을 자동으로 찾는다.
다른 설치 구조에서는 다음 환경변수 또는 대응하는 CLI 옵션을 사용한다.

```zsh
export BEOLMURI_EVAL_MODEL="$MODEL_PATH"
export BEOLMURI_EVAL_LITERT_PYTHON="$LITERT_PYTHON"
beolmuri-eval doctor --json
```

모델을 지정하지 않으면 LiteRT-LM 로컬 registry의 `gemma4-e2b`를 찾는다.
모델 이름만 신뢰하지 않고 `ai/models/runtime-models.json`의 크기·SHA-256과
대조한다. 다른 모델이나 런타임으로 자동 대체하지 않는다.

## 평가 파일 구조

```text
configs/name-identity.yaml          실행·실험·채점기 설정
datasets/name-identity.jsonl       입력 데이터, 한 줄에 한 사례
judges/name-identity.md             의미 판정 기준
schemas/name-case.schema.json      입력 행 계약
schemas/name-judgment.schema.json   채점 출력 계약
schemas/evaluation.schema.json     YAML 설정 계약
```

평가 코드에는 이름·질문 목록이나 실험 이름 목록을 두지 않는다. YAML의
`dataset.path`를 바꾸면 다른 JSONL 데이터셋을 평가한다. `variants`에 이름과
Swift 설정을 추가하면 Python 수정 없이 해당 실험을 선택할 수 있다.
YAML 안의 파일 경로는 실행한 터미널 위치가 아니라 **YAML 파일의 디렉터리**를
기준으로 해석한다. 절대경로도 사용할 수 있다.

데이터셋의 한 쌍은 다음처럼 표현한다.

```jsonl
{"id":"wrong-001","pair_id":"pair-001","kind":"wrong_name","character_name":"엘레나","called_name":"아영","user_message":"아영아, 오늘 뭐 했어?"}
{"id":"correct-001","pair_id":"pair-001","kind":"correct_name","character_name":"엘레나","called_name":"엘레나","user_message":"엘레나야, 오늘 뭐 했어?"}
```

모든 행은 위 필드를 갖는다. `id`는 파일 전체에서 유일하며, 같은 `pair_id`에
잘못된 호명과 정상 호명 한 건씩 있어야 한다. 두 행의 캐릭터는 같아야 한다.
잘못된 이름은 캐릭터 이름과 달라야 하고, 정상 호명은 같아야 한다. ID에는
영문·숫자·점·밑줄·하이픈만 사용하며 첫 글자는 영문 또는 숫자다.
공백뿐인 이름·발화, 중복 키, 추가 필드, 깨진 JSON은 행 번호와 함께 거부한다.

```zsh
# 파일 계약 확인만 수행하며 모델이나 채점기를 호출하지 않는다.
beolmuri-eval validate
beolmuri-eval validate --config ai/beolmuri-eval/configs/name-identity.yaml

# 자신의 YAML 파일로 실행한다.
beolmuri-eval run --config path/to/evaluation.yaml
```

생성의 샘플링 설정은 기존처럼 Swift 제품 코드에서 읽는다. YAML은 입력과
실험 구성을 소유하며 페르소나 조립·응답 처리 로직을 재구현하지 않는다.
채점 provider/model/reasoning은 합의한 Codex CLI/Luna/medium 계약으로 검증한다.

## 평가와 어블레이션

설정 파일을 생략하면 `configs/name-identity.yaml`을 사용한다.
`--variant`, `--repeats`, `--timeout`은 YAML의 `run` 값을 명시적으로 덮어쓴다.
`--limit-pairs`는 데이터셋의 등장 순서대로 지정한 쌍만 선택한다. 생략하면 전부 사용한다.

```zsh
# 빠른 연결 점검: 잘못된 이름과 정상 이름 한 쌍
beolmuri-eval run --variant baseline --limit-pairs 1 --repeats 1

# 전체 초안: 20쌍 × 3회 = 120응답
beolmuri-eval run --variant baseline
beolmuri-eval run --variant name-rule
beolmuri-eval run --variant answer-only
beolmuri-eval run --variant combined

beolmuri-eval compare <baseline-run-id> <candidate-run-id>
beolmuri-eval inspect <run-id> --failures
beolmuri-eval status <run-id>
beolmuri-eval cancel <run-id>
beolmuri-eval resume <run-id>
```

| 설정 | 페르소나·장면 | 세션 정보 | 이름 지시 | 메모리 분류·헤더 처리 |
| --- | --- | --- | --- | --- |
| baseline | 포함 | 포함 | 제외 | 포함 |
| name-rule | 포함 | 포함 | 포함 | 포함 |
| answer-only | 포함 | 포함 | 제외 | 제외 |
| combined | 포함 | 포함 | 포함 | 제외 |
| name-only | 제외 | 제외 | 포함 | 제외 |
| persona-name | 포함 | 제외 | 포함 | 제외 |
| persona-name-memory | 포함 | 제외 | 포함 | 포함 |

Swift의 실험 훅은 `includePersona`, `includeSessionContext`,
`enforceCharacterName`, `memoryClassification` 네 불리언으로 구성한다.
YAML의 각 variant에는 네 값을 모두 명시한다. `includePersona`는 페르소나
본문과 활성 장면 카드를 함께 제어하고, `includeSessionContext`는 캐릭터 이름
등 앱 제공 프로필 정보만 제어한다. 사용자 입력의 래퍼와 빈 이력·기억 조건은
그대로 유지한다. 이름 지시는 세션 정보가 없어도 설정된 캐릭터 이름을 사용한다.

```yaml
name-only:
  includePersona: false
  includeSessionContext: false
  enforceCharacterName: true
  memoryClassification: false
```

```zsh
# 각 명령은 한 쌍 × 3회 = 6응답이며, 세 명령 합계는 18응답이다.
beolmuri-eval run --variant name-only --limit-pairs 1 --repeats 3
beolmuri-eval run --variant persona-name --limit-pairs 1 --repeats 3
beolmuri-eval run --variant persona-name-memory --limit-pairs 1 --repeats 3
```

실험 조합 변경에는 YAML만 수정하면 되며 Swift를 다시 빌드할 필요가 없다.
각 run 내부에서는 GPU 엔진을 재사용하고 입력마다 새 대화를 만든다.
별도 run 사이에는 엔진을 공유하지 않는다. 선택한 설정과 실제 system/user
프롬프트는 턴별 `input`에 함께 저장한다.

각 variant에 `thinking: true` 또는 `thinking: false`를 추가하면 평가 실행부가
해당 추론 모드를 사용한다. 생략하면 Swift 제품의 `responseThinkingDefault`를
따른다. `name-rule-thinking`은 `name-rule`과 프롬프트가 같고 추론 모드만 켠
비교 조건이다. 실제 적용값은 `input.sampling.thinking`에 기록한다.

샘플링 비교는 variant에 `sampling: {temperature: 1.0, top_k: 64, top_p: 0.95}`를
추가한다. 지정할 때는 세 값을 모두 제공하며, 생략하면 제품 기본값을 사용한다.
프롬프트와 제품 설정은 바뀌지 않고 평가 생성 요청에만 적용된다.
선택값은 `configuration.sampling`, 실제 전달값은 `input.sampling`에 기록한다.

이름 유지 지시는 시스템 프롬프트의 마지막에 배치한다. 캐릭터 이름을
따옴표로 구분하고, 잘못된 호명에는 대화 답변의 첫 문장에서 이름을 바로잡은
뒤 질문에 반응하도록 지시한다. 메모리 분류가 켜져 있으면 이 첫 문장은
`save(...)` 다음 줄에 해당한다. 짧은 대화 예시는 표시 답변만 보여준다.
호명과 제삼자에 대한 언급을 구분하도록 하며, 판단 과정 출력을 요구하지 않는다.

메모리 분류를 제외하는 실험은 지시 문장만 제거하는 실험이 아니다. Swift에서
저장 헤더 파싱과 분류 전용 재시도도 함께 제외한다. 기준선은 기존
`MemoryTaggedChatProcessor`를 사용하며 답변이 없으면 같은 네이티브
conversation에서 기존 답변 전용 재시도를 실행한다.

기본 JSONL에는 다섯 이름과 네 질문의 조합을 40개 행으로 저장해 두었다. 각 입력에는 이름만 올바르게 바꾼
대조 입력이 있다. 대조 질문은 쌍 사이에서 반복되므로 서로 다른 20종의
정상 질문으로 해석하지 않는다. 모든 입력은 새 conversation에서 시작한다.

## 채점과 수치

기본 채점은 Codex CLI provider의 `gpt-5.6-sol`, reasoning `medium`을 사용한다.
채점 모델은 YAML의 `judge.model`에서 선택하며, 과거 실험은 저장된 설정으로 재현한다.
채점 모델을 바꿔 비교할 때는 같은 생성 응답을 재채점하고 모델별 판정을 따로 보관한다.
채점기에는 실험 이름, 변경한 시스템 프롬프트나 개선 의도를 전달하지 않는다.
올바른 이름, 부른 이름, 사용자 발화, 최종 표시 응답과 고정 rubric만 전달한다.

| 판정 | 의미 |
| --- | --- |
| identity_maintained | 자신의 이름을 유지하며 잘못된 호명을 정정하거나 대상을 확인 |
| explicit_acceptance | 다른 이름을 자신의 이름으로 명시적으로 수용 |
| uncorrected_response | 잘못된 호명을 짚지 않고 응답 |
| unjudgeable | 빈 응답·무관한 말 등으로 의미 판정 불가 |

네 판정의 비율은 **채점 완료 응답 전체**를 분모로 계산하며 unjudgeable을
분모에서 제외하지 않는다. 생성 오류와 채점 오류는 별도로 집계한다. 채점이
빠진 결과의 비율은 잠정치이며 `grading_coverage_pct`와 `complete`를 함께 본다.
정상 호명 오정정률도 별도로 계산하고 판정 불가 비율을 함께 표시한다.

합격 임계값이나 임의 종합점수는 없다. `compare`는 프롬프트·모델·기억·예산이 달라도
두 조건의 집계와 manifest 차이를 출력한다. 손상되거나 중복된 응답 기록은 오류다.
짝 비교는 같은 case/repeat 키, 현재 발화, 캐릭터, 호명, 평가 종류를 가진 채점 완료
응답에 한정한다. 누락·미채점·대상 변경은 제외 사유와 함께 기록하며, 유효한 짝이
없으면 `paired.available=false`다. 채점기나 채점 기준이 바뀌면 짝 비교와 비율 차이는
제공하지 않고 각 조건의 집계만 제공한다. 제어군이 없으면 제어군 차이는 `null`이다.
전체 집계의 차이와 일부 일치 표본의 전환 수는 분모가 다를 수 있다. 설정 차이와
채점 완료율을 확인하고, 작은 연결 점검만으로 성능 개선을 확정하지 않는다.

## 산출물과 실패 처리

각 run은 `.artifacts/runs/<run-id>/inputs/`에 사용한 YAML·JSONL·채점 기준·출력
스키마의 원본 사본을 보관한다. manifest에는 파일별 해시와 실제 선택한 입력·
실험 설정·CLI 덮어쓰기 결과를 기록한다. 같은 run 디렉터리에 턴별 atomic JSON,
events.jsonl, worker 로그와 summary를 저장한다. 프롬프트, 모델 해시,
소스 해시, 생성 설정, 원문 chunk, 최종 표시 응답, 재시도와 판정 근거를 남긴다.
첫 출력 시간과 생성 시간을 기록하며 지원하지 않는 토큰 수·기기 메모리·
열 상태 지표는 null 또는 UNVERIFIED로 남긴다.

진행률과 heartbeat는 stderr에 출력한다. 잠금 파일의 실제 소유 여부로 동시
실행을 막는다. Ctrl-C/cancel 시 자식 프로세스도 정리하고 완료된 턴은 유지한다.
생성이 완료된 턴은 재개할 때 다시 생성하지 않고 필요한 채점만 실행한다.
생성 도중 중단된 턴은 새 conversation에서 다시 실행한다. 외부 YAML·JSONL·
채점 기준 원본을 수정해도 기존 run은 저장된 사본과 설정으로 재개한다.
수정한 원본은 새 실행에만 반영된다. 실행 코드·의존성·모델·런타임이 바뀌거나
run 내부 사본이 손상되면 재개를 거부한다.

종료 코드는 0=명령 성공, 1=실행/환경 오류, 2=평가 채점 미완료, 130=중단이다.
명령 성공은 모델의 품질 합격을 뜻하지 않는다.

## 평가 데이터 경계

이 CLI의 입력 계약은 `dataset.data_class: synthetic`이다. 합의된 합성 평가
데이터를 JSONL로 작성하며, 파일에 실제 플레이어 정보를 넣지 않는다. 실제 플레이어 대화나
앱 메모리 DB를 읽는 경로는 없다. 원격 채점은 사용자가 요청한 평가 기능이며
제품에는 추가되지 않는다. 로컬 결과는 사용자가 해당 run 디렉터리를 삭제할
때까지 보관한다. 원격 제공자의 보관·삭제 정책은 Codex 계정 설정을 따르며
로컬 파일 삭제가 원격 삭제를 의미하지 않는다. 채점 실패 시 응답을 보존하고
오류로 기록하며 다른 모델로 대체하지 않는다. 결과 폴더는 Git에서 제외한다.

## 개발 검증

```zsh
swift test --package-path ios/EdgeLLM
beolmuri-eval build
uv run --project ai/beolmuri-eval python -m unittest discover -s ai/beolmuri-eval/tests
```

LiteRT-LM의 Python conversation API에는 출력 토큰 제한 인자가 없어, 고정
버전의 C API 어댑터에서 세션 출력 제한을 명시적으로 설정한다. 이 어댑터는
모델 실행만 담당하며 이름 규칙·메모리 지시·응답 파싱을 구현하지 않는다.


## 이름 지시 구조의 반복 실험

[실험 설정과 계획](experiments/name-structure/README.md)은 짧은 이름 지시를
앞에 둔 `identity-statement`와 정정 행동·예시를 마지막에 둔 `response-action`을
비교한다. `nameRuleStyle`을 YAML에서 선택하며 Swift가 두 구조를 직접 조립한다.
생략하면 이름 규칙을 켠 실험은 `response-action`을 사용한다. 제품 기본값은
`enforceCharacterName: true`, `nameRuleStyle: response-action`이다. 실험 결과
문서의 비활성 기본값 설명은 해당 실험 실행 시점의 조건이다.

채점은 단순 이름 언급과 명확한 자기 이름 정정을 구분한다. 보정 전 예비
수치를 새 기준의 수치와 합산하지 않는다. 공개 가능한 합성 증거를 내보낼 때는
실험 폴더의 `export.py`를 사용하며, 로컬 경로와 CLI 세션 로그는 제외한다.

### Author’s Note 설정

기존 YAML의 원하는 variant 안에 `authorsNote`를 추가한다. 아래 문구는 연결 예시이며
품질 검증을 거친 지시가 아니다. 다른 variant와 동일한 이력·기억·샘플러를 유지하면
노트 위치와 주기를 독립적으로 비교할 수 있다.

```yaml
    authorsNote:
      defaults:
        text: "엘레나의 말투를 유지하면서 사용자의 질문에 답한다."
        interval: 1
        position: in-chat
        depth: 1
        role: system
      allowWorldInfoScan: false
```

`chat`으로 개별 필드를 재정의하고, `character: {text: "...", enabled: true, mode: before}`로
캐릭터별 본문을 합성할 수 있다. 위치는 `in-chat`, `before-system`, `after-system`이다.
`in-chat` 깊이 0은 현재 발화 뒤, 1은 앞이다. 시스템 역할은 요청 메타데이터이며,
이력 중간 노트는 실제 LiteRT-LM 사용자 문자열에 들어간다.

`beolmuri-eval validate --config <설정.yaml>`으로 설정을 검사하고,
`beolmuri-eval measure-context --config <설정.yaml>`으로 추론 없이 최종 입력과 토큰을
확인한다. 측정에는 배포 모델과 네이티브 토크나이저가 필요하다.
`prompt_trace.authorsNote`의 상태·누적 사용자 번호와 `insertions`의 위치·실제 역할을
확인할 수 있다. 노트를 켜도 전체 입력·출력 예산은 그대로 적용되며, 초과하면 노트를
몰래 제거하지 않고 오류를 반환한다. 설정과 추적은 실행 기록에 함께 저장된다.

### World Info 설정

토큰 예산을 켠 평가 YAML의 variant 안에 `worldInfo`를 추가한다. 다음은 합성 자료를
이용한 연결 예시이며 품질 튜닝 값이 아니다. 기존 데이터셋·이력·기억 파일은 그대로 쓸 수 있다.

```yaml
    worldInfo:
      tokenBudget: 512
      scanDepth: 2
      includeNames: false
      entries:
        - id: cafe
          keys: [카페]
          secondaryKeys: [서울, 산책]
          secondaryLogic: AND_ANY
          content: "별빛 카페는 마을 중앙에 있다."
          order: 100
          position: after-character
        - id: cafe-note
          keys: [카페]
          content: "카페 설명은 지금 질문에 필요한 만큼만 사용한다."
          position: before-note
```

`worldInfo`에는 실제 토크나이저를 연결하는 상위 `prompt_budget`과 `runtime` 설정이
필요하다. 기존 바이트 실험에 WI만 추가하면 검증 오류가 발생한다. 주기·깊이는 같은
variant의 `authorsNote`로 조절한다. 노트 설정이 없으면 빈 기본 노트를 사용한다.
자료는 실행 manifest와 설정 스냅샷에 보존된다.

`validate --config <설정.yaml>`은 설정 형식과 토큰 경로 유무를 검사한다.
`measure-context --config <설정.yaml>`은 공용 Swift 선택·합성과 최종 입력 계측을
추론 없이 수행한다. `prompt_trace.worldInfo`에서 선택/제외 이유와 실제 삽입 여부를
확인한다. 세부 자료 검증(중복 ID, 미지원 키 구문 등)은 Swift 준비 단계에서도 수행한다.
지원 범위와 예산 경계는 `ios/EdgeLLM/README.md`의 World Info 절을 따른다.

### World Info 고급 선택과 원본 파일 조작

`worldInfo.rules`에서 재귀·최소 활성화·최대 반복·그룹 점수·비율 예산을 설정하고,
각 항목의 `rules`에서 그룹/확률/기간/필터/깊이/아웃렛을 설정한다.
예: `rules: {recursive: true, maximumSteps: 10}`,
항목에는 `rules: {sticky: 4, cooldown: 2, probability: 80}`.
설정 필드는 스키마가 정본이며 지원 범위와 원본 차이는 `ios/EdgeLLM/README.md`에 있다.

원본 로어북 조작은 추론 없이 공용 Swift 코어를 호출한다.

```sh
beolmuri-eval build
beolmuri-eval world-info inspect --book lorebook.json --name village
beolmuri-eval world-info upsert --book lorebook.json --name village --entry entry.json --output edited.json
beolmuri-eval world-info remove --book lorebook.json --name village --entry-id village.3 --output removed.json
beolmuri-eval world-info export --book lorebook.json --name village --output exported.json
```

`entry.json`은 정규화된 WorldInfoEntry 객체다. 기존 파일은 덮어쓰지 않는다.
원본 주석·메타데이터는 보존하며 지원하지 않는 실행 필드는 오류로 알린다.
평가 worker의 `prepare`는 선택적인 worldInfoContext/worldInfoState/worldInfoText/exampleDialogue를
받고 다음 상태인 world_info_transaction을 반환한다. 벡터 검색 평가는 명시적인 검색 결과
fixture를 요구한다. 앱의 로컬 임베딩 실행과 fixture 기반 선택 검증을 혼동하지 않는다.


## 로어북과 여러 턴 시나리오

`configs/dialogue-world-info.yaml`은 원본 로어북 JSON과 합성 대화를 연결하는 실행 예시다.
예시는 연결 확인용이며 자연스러움 평가셋이나 튜닝된 최적 설정이 아니다.

```zsh
beolmuri-eval validate --config ai/beolmuri-eval/configs/dialogue-world-info.yaml
# 실제 추론과 원격 이름 채점을 시작할 때만 실행한다.
beolmuri-eval run --config ai/beolmuri-eval/configs/dialogue-world-info.yaml
```

`validate`는 모든 variant의 파일·스키마와 Swift World Info 설정을 검사한다.
Swift 실행부를 빌드하지만 모델을 로드하거나 원격 채점기를 호출하지 않는다.

YAML은 실험 설정이고 `lorebooks`는 이름과 원본 JSON 파일 경로의 대응표다.
`worldInfo.library`에서 전역·캐릭터·채팅·페르소나별 연결과 우선순위를 지정한다.
본문은 JSON에만 작성한다. 이름이 같은 inline book과 파일을 동시에 지정하면 오류다.
로어북 원본도 실행의 `inputs/`에 해시와 함께 고정한다. Character Card 전체를
가져오는 기능은 포함하지 않는다.

`dataset.format: scenarios`의 JSONL 한 줄은 한 대화다.

```json
{"id":"park","character_name":"엘레나","turns":[{"id":"intro","user_message":"공원에 가자."},{"id":"probe","user_message":"아영아, 안녕?","kind":"wrong_name","called_name":"아영"}]}
```

- `kind`를 생략한 턴은 `dialogue`다. 응답을 생성해 이력에 넣고 이름 채점은 하지 않는다.
- `wrong_name`·`correct_name` 턴은 기존 네 가지 판정으로 채점한다. 자연스러움 판정은 아직 없다.
- `pair_id`는 조건 간 공통 난수 그룹이다. 없으면 시나리오 ID를 사용한다.
- 턴별 `memories`, `world_info_context`, `example_dialogue`로 고정 입력을 지정할 수 있다.
  `world_info_context`는 variant 기본값에 턴 값을 덮어쓴다. 벡터 검색을 켜면 매 턴의
  `vectorMatches`를 명시해야 하며 빈 검색 결과는 `[]`로 쓴다. 실제 임베딩 검색 실행이 아니다.
- 기존 이름 JSONL은 `format`을 생략한다. 각 행이 독립 세션이다. `dataset.kind`로
  잘못된 이름만 고르는 기존 실험을 지원하지만 시나리오의 중간 턴은 필터로 제거하지 않는다.

Swift의 체크포인트에 최근 이력, 누적 메시지 수, Sticky·Cooldown·매크로 상태를 보관한다.
같은 시나리오의 다음 턴만 이 상태를 받는다. 시나리오·반복이 바뀌면 초기화한다.
응답과 다음 체크포인트는 한 파일로 원자 저장한다. 채점 실패는 상태를 되돌리지 않으며,
중단된 생성은 이전 상태에서 재시도한다. 연결이 끊기거나 해시가 바뀐 기록은 재개 전에 거부한다.
`input.session_clock`, `session_after`, `seeds`, `input.prompt_trace`로 실제 적용 상태를 확인한다.

각 턴의 LiteRT conversation은 공용 Swift가 구성한 입력에서 새로 시작한다. 여러 턴의
KV를 중복 누적하지 않는다. 논리적 이력과 World Info 상태는 체크포인트로 이어진다.
EdgeMem 검색·저장과 도구 실행은 이 시나리오 러너가 수행하지 않으며 기존 앱 기능을 변경하지 않는다.
후속 발화의 토큰 수는 앞선 실제 응답에 따라 달라지므로 `measure-context`는 시나리오를
거부한다. 실행 기록의 토큰 계측을 사용한다.

CLI를 다른 checkout에 재설치하면 기본 결과 위치도 바뀐다. 과거 결과는 명시적인
실행 디렉터리로 조회할 수 있으며, 결과 디렉터리를 연결했다면 `doctor`에 실제 경로가 표시된다.
소스가 다른 기존 실행을 새 코드로 재개하지 않는다. 새 결과와 비교·조회는 가능하다.


실험별 `export.py`는 공용 내보내기를 호출한다. 비교 응답은 `baseline.jsonl`과
`candidate.jsonl`, 반복별 집계는 `evidence.json`에 저장한다. 기존 결과와 섞이지 않도록
새 출력 디렉터리를 지정해야 한다. 로컬 경로에 해당하는 출처 필드와 채점 CLI 로그를 제외하며
평가 발화·응답·인용 근거는 변경하지 않는다. 과거 결과 파일을 자동으로 덮어쓰지 않는다.

`beolmuri-eval run --config path/to/evaluation.yaml --output-root /private-evaluation/runs`로
입력 사본과 결과를 저장소 밖에 직접 저장할 수 있다. 출력 폴더 아래에는 실행별 디렉터리를
만들며, `resume`, `inspect`, `status`에는 해당 실행 디렉터리의 경로를 전달한다.

### 보존한 모델 요청 재실행

`beolmuri-eval replay`는 이미 조립된 시스템·사용자 문자열과 직접 지정한 시드를
그대로 native adapter에 전달한다. 과거 실험 재현을 위한 경로이며 Swift 앱 조립기,
World Info, 메모리 분류·응답 재시도를 실행하지 않는다. 앱 경로 검증은 `run`을 쓴다.

```sh
beolmuri-eval replay --requests requests.jsonl --output replay-run
beolmuri-eval status replay-run
beolmuri-eval resume replay-run
```

JSONL의 각 요청에는 `id`, `system_prompt`, `user_prompt`, `seed`, `max_num_tokens`,
`sampling`을 제공한다. `sampling`은 `temperature`, `top_k`, `top_p`,
`max_output_tokens`, `thinking`, `filter_channel_content_from_kv_cache`를 모두 포함한다.
출처 등의 추가 메타데이터는 기록에 보존하지만 모델에 전달하지 않는다.
한 실행은 동일한 컨텍스트 용량을 사용한다. `--model`, `--litert-python`으로
배포 모델과 런타임 환경을 지정할 수 있다.

매 요청의 원문, 전달 설정, 원시 응답과 시간을 기록한다. `answer`는 과거 비교용으로
양끝 공백만 제거하며 `raw_text`는 그대로 보존한다. 실패는 저장하고 중단한다.
재개 시 입력·실행 코드·환경 변경을 거부하며 완료된 요청을 다시 생성하지 않는다.
채점은 별도 단계다. 재현 성공을 앱의 대화 품질이나 자동 검색 성공으로 해석하지 않는다.

### 반응풀 검색 연결

`build-reactions --source authored-items.jsonl --character <id> --model <embedding.tflite> --tokenizer <sentencepiece.model> --output <private-directory>`는 `ready` 반응틀의 검색 예시를 미리 임베딩합니다. `retrieval` 선택 의존성이 설치된 환경에서 실행합니다. 문서 전처리는 EmbeddingGemma의 `title: none | text:`, 질의는 `task: search result | query:`이며 native 앱과 같은 256 토큰 입력입니다. 진행률·예상시간과 체크포인트를 저장하며, 같은 명령으로 재개합니다. 의미적 중복이나 품질을 재채점하지 않고 보류·형식 불량만 제외합니다.

평가 variant에 다음 설정을 추가합니다. `content`와 `prompt_budget`도 필요합니다.

```yaml
retrieval:
  directory: <private-directory>
  model: <embedding.tflite>
  tokenizer: <sentencepiece.model>
  reactions: true
  worldLore: true
```

반응 검색과 세계관 주입을 각각 끌 수 있습니다. 최근 3개 **메시지**(현재 발화 포함)를 시간순으로 연결하고, 예시별 코사인 점수의 최댓값으로 반응틀 하나를 선택합니다. 임계값은 없습니다. 선택과 프롬프트 조립은 앱과 동일한 Swift 코드가 수행합니다. Python은 임베딩·토큰 계측만 제공합니다. 긴 질의는 native 앱과 동일하게 256 토큰으로 잘리므로, K=3이 세 메시지의 전체 내용을 보장하지는 않습니다.

`input.retrieval_trace`에는 선택 ID·유사도·예시 행·질의·임베딩 왕복시간·검색시간이 저장됩니다. 첫 임베딩 시간에는 모델 초기화가 포함됩니다. `prompt_trace.tokenBudget.sections`의 `worldInfo.depth.0.system`은 반응틀 구간 토큰 수이며, 다른 같은 위치의 항목이 있다면 합산 구간입니다. 정확한 총 입력은 `inputTokens`로 확인합니다. 반응틀은 로어북의 별도 예산에서는 제외하지만 전체 모델 입력·출력 상한은 그대로 검사합니다.

실행 시작 시 인덱스와 로어북을 `inputs/`에 복사합니다. 재개 시에는 복사본을 사용하며, 외부 임베딩 모델·토크나이저는 인덱스에 기록한 해시 기반 식별자와 일치해야 합니다. 추론용 Python 환경에도 `numpy`, `sentencepiece==0.2.1`, `ai-edge-litert==2.1.3`이 필요합니다. 생성 원문과 런타임 자료는 Git 밖에 둡니다.
