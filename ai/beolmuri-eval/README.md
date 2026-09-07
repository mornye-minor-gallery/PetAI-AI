# Beolmuri Eval

status:: active

캐릭터를 다른 이름으로 불렀을 때 이름을 유지하는지 평가하는 실험 CLI다.
페르소나 지시, 출력 해석과 재시도 판단은 제품의 `EdgeLLM` Swift 코드를
실행한다. Python은 실행 관리, LiteRT-LM 연결, Codex CLI 채점과 수치 집계를
담당한다. Unity를 실행하거나 제품의 대화 로직을 Python으로 재작성하지 않는다.

## 실행 범위

초안은 **단일 턴, GENERAL 장면 고정, 빈 기억, 빈 대화 이력**을 사용한다.
장면 라우터, EdgeMem 검색·저장, OS 도구 실행과 Unity UI의 통합 평가는 아니다.
제품의 기본 프롬프트와 응답 처리 동작은 변경하지 않으며 실험 설정은 평가
실행부에서만 선택한다. 평가 실행 파일은 앱의 release target에 포함하지 않는다.

Gemma는 제품 모델 레지스트리의 `.litertlm` 파일을 GPU에서 실행한다.
macOS에서는 WebGPU를 통해 Metal을 사용하며, GPU 초기화 실패는 오류로 보고한다.
일반 `doctor`의 GPU 표시는 설정값이며, 실제 생성 검증은 `doctor --probe`로 수행한다.
Mac 어댑터는 `litert-lm==0.13.1`을 고정하며 모바일의 0.14.0 fork와 버전이
다르다. Mac의 결과를 iPhone 런타임·메모리·발열 검증으로 해석하지 않는다.
생성 설정은 Swift의 `SLMConfiguration.production`에서 받는다. 반복 실행의
seed는 반복 인덱스이고, 제품과 같은 고정 seed의 반복이나 비트 단위 재현성을
주장하지 않는다. 추측 디코딩은 끄고 KV 용량은 모델 기본값을 사용한다.

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

Codex CLI provider의 `gpt-5.6-luna`, reasoning `medium`을 사용한다.
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

합격 임계값이나 임의 종합점수는 없다. compare는 같은 데이터·반복·모델·런타임·
채점 조건에서 모든 입력의 채점이 완료됐을 때만 실행한다. 각 비율의
퍼센트포인트 차이와 동일 입력의 성공/실패 전환 수를 출력한다. 적은 수의
연결 점검 결과만으로 성능 개선을 확정하지 않는다.

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
생략하면 이름 규칙을 켠 실험은 `response-action`을 사용한다. 제품 기본값의
`enforceCharacterName: false`에는 영향을 주지 않는다.

채점은 단순 이름 언급과 명확한 자기 이름 정정을 구분한다. 보정 전 예비
수치를 새 기준의 수치와 합산하지 않는다. 공개 가능한 합성 증거를 내보낼 때는
실험 폴더의 `export.py`를 사용하며, 로컬 경로와 CLI 세션 로그는 제외한다.
