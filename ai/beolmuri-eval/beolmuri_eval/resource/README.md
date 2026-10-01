# iOS 자원 측정

현재 지원하는 경로는 `inference` 대상의 `basic` 프로필이다. Unity와 상세 계측은 설계에 포함되지만 아직 실행할 수 없다. 일반 앱과 구별되는 `.resourcebench` 번들을 사용한다.

평가 하네스 디렉터리에서 실행한다.

```sh
uv run beolmuri-eval resource build --signed
uv run beolmuri-eval resource validate --config experiment.yaml
uv run beolmuri-eval resource doctor --device DEVICE_ID --json
uv run beolmuri-eval resource provision --config experiment.yaml --device DEVICE_ID
# 빠른 추론·RAM 확인: 전력 수집기와 유휴 대조군을 실행하지 않는다.
uv run beolmuri-eval resource inference --config experiment.yaml --device DEVICE_ID --app APP_PATH --model-preinstalled
# 동일 입력을 fresh/cached 순서로 실행하고 바로 비교한다.
uv run beolmuri-eval resource kv-cache --config experiment.yaml --device DEVICE_ID --app APP_PATH --model-preinstalled
# 모델 전송·왕복 검증 후 선을 분리하고 Wi-Fi에 다시 연결한다.
uv run beolmuri-eval resource run --config experiment.yaml --device DEVICE_ID --app APP_PATH --model-preinstalled
uv run beolmuri-eval resource status RUN_DIRECTORY
uv run beolmuri-eval resource cancel RUN_DIRECTORY
uv run beolmuri-eval resource collect RUN_DIRECTORY
uv run beolmuri-eval resource resume RUN_DIRECTORY
uv run beolmuri-eval resource recover RUN_DIRECTORY
uv run beolmuri-eval resource summarize RUN_DIRECTORY
uv run beolmuri-eval resource compare BASELINE_RUN CANDIDATE_RUN
```

`APP_PATH`는 빌드 출력의 실제 앱 경로다. 빌드 정보는 저장소의 `ios/.artifacts/resource-benchmark/build.json`에 남는다. 서명에는 로컬 Xcode 개발 계정과 프로파일이 필요하다. 기기에서 개발자 신뢰가 필요하면 직접 확인해야 한다. `doctor`의 준비 표시는 앱 설치 여부까지만 뜻하며 전경 실행·추론·계측 성공을 보장하지 않는다.

설정 형식은 `contracts/resource-benchmark/config.schema.json`, 묶인 명세 예시는 `contracts/resource-benchmark/examples/manifest.json`을 따른다. 입력·모델 목록·생성 설정·초기 상태 파일 경로는 설정 파일 기준이다. 현재는 CPU 언어 모델 하나와 빈 초기 상태를 사용하며, 요청별 새 대화와 단일 세션의 전체 입력 교체를 지원한다. 모델 목록에는 로컬 경로와 실제 SHA-256을 지정한다. 저장소에 모델 파일이나 개인 기기 식별자를 추가하지 않는다.

`resource run`은 동일 길이의 유휴·작업 창을 번갈아 기록하는 엄격한 전력 실험이다. `resource inference`와 `resource kv-cache`는 전력 수집기를 만들지 않고 입력 목록을 정확히 한 번씩 실행하여 지연 시간과 RAM을 확인한다. 메모리는 앱의 `phys_footprint`이며 추론 전후 차이를 순수 액티베이션으로 해석하지 않는다. 전력은 Power Profiler가 내보내는 기기 전체 `%/hr`를 해당 창에서 시간 가중한다. 앱 단독 와트나 줄로 환산하지 않는다. 창 경계·누락·표식·상태 검증에 실패하면 숫자를 채우지 않고 이유를 남긴다.

추론 작업은 LiteRT-LM 0.17.1이 제공하는 `Conversation.getTokenCount()`와
`BenchmarkInfo`를 함께 기록한다. 요청 전후 KV 토큰 수, 네이티브 TTFT, 마지막
prefill·decode 토큰 수와 처리량을 `summary.json`의 `native_inference`에 발화별로
남긴다. 필드가 없거나 유효하지 않으면 해당 실행을 완전한 결과로 판정하지 않는다.
일반 앱은 실험용 benchmark 수집을 켜지 않으며 자원 측정 빌드에서만 활성화한다.

최초 모델 전송은 `provision`으로 측정과 분리한다. 전송 후 기기 파일을 다시 내려받아 SHA-256을 검증하며, 반환된 파일도 전송 증거로 보존한다. `--model-preinstalled`는 재전송만 생략하고 앱의 모델 해시 검증은 유지한다. 전송 완료는 모델 로드나 추론 성공을 뜻하지 않는다.

무선 측정에서는 충전선을 분리하고 화면 잠금을 풀어 둔다. 측정 앱은 실행 중 자동 잠금을 억제하지만 전원 버튼으로 잠그거나 다른 앱으로 전환하면 실험 조건을 만족하지 못한다. 모델 전송과 해시 확인은 측정 창 밖에서 수행한다.

원본과 실패 기록은 `.artifacts/resource-runs/`에 보존한다. 추론 전용 경로는 `created → app_ready → running → device_finished → collected → analyzed → closed` 체크포인트를 원자적으로 기록한다. 기기 실행이 끝난 뒤 회수만 실패하면 `resume`이 추론을 다시 실행하지 않고 회수부터 이어 간다. 이전 소유권은 `recover`가 기기 상태 또는 실제 프로세스 부재를 확인한 경우에만 닫는다. 일반 실패를 자동으로 재시도하거나 불확실한 소유권을 지우지 않는다. 전력 경로는 기존 보수적 중단 정책을 유지한다.

`resource agentctl` 뒤에는 같은 명령을 전달할 수 있다. 예약 취소는 `cancel RUN_DIRECTORY --after-ms MILLISECONDS`를 사용한다. 화면 캡처와 강제 종료 인터페이스는 아직 제공하지 않는다.

전력 수집은 `--all-processes`를 사용하고 분석 구간은 앱의 실행 ID·PID로 제한한다. 수집 범위가 다른 결과는 기본 비교를 거부한다. 각 구간 뒤에는 하네스가 소유한 측정 앱을 종료하고 다음 구간에서 다시 실행한다. 화면이 닫히는 것만으로 충돌로 판정하지 않으며 종료 명령·앱 상태·기기 오류를 대조한다.

`phys_footprint`에는 수정되지 않은 파일 매핑 페이지 등이 모두 포함되지 않으므로 전체 물리 RAM 사용량과 같지 않다. 런타임 캐시의 최초 생성 여부는 현재 자동 통제·비교 검증 대상이 아니다. 서로 다른 실행의 차이를 모델이나 문맥 길이만의 영향으로 단정하지 않는다.

Instruments가 종료 후 심벌 처리 중 정체하면 실패로 기록하고 원본과 소유권을 보존한다. 다음 실험 전에 실제 수집기 종료 확인이 필요하다. 일반 TestFlight 빌드에 계측을 사후 주입하는 외부 관측은 제공하지 않는다.

## 실제 Unity 앱의 RAM 진단

`resource unity`는 실제 앱의 `ChatSession → iOS bridge → 검색·프롬프트·추론` 경로를 측정한다. 별도 엔진을 만들지 않는다. 기존 `resource run`의 추론 단독·전력 실험과 별개의 RAM 전용 모드이며 USB 연결도 허용한다. 결과는 `.artifacts/unity-resource-runs/`에 저장된다.

빌드에는 명시적으로 `RESOURCE_BENCH`가 필요하다. 일반 빌드에는 실행 제어·기록 코드가 포함되지 않는다.

```sh
beolmuri-eval resource build --target unity --unity-editor UNITY_EXECUTABLE --dialogue-content COMPILED_DIALOGUE_JSON
beolmuri-eval resource unity run --device DEVICE_ID --bundle com.byeolmuri.app --config ../../contracts/resource-benchmark/examples/unity-diagnostic.json
beolmuri-eval resource unity status RUN_DIRECTORY
beolmuri-eval resource unity collect RUN_DIRECTORY
beolmuri-eval resource unity summarize RUN_DIRECTORY
beolmuri-eval resource unity cancel RUN_DIRECTORY
```

`run` 전에 측정 빌드를 설치하고 앱을 완전히 종료한다. 로그인과 모델 다운로드를 완료한 앱 상태를 사용한다. 실행 후 홈 화면의 대화 컨트롤러가 준비되면 지정된 캐릭터·플레이어명으로 발화를 자동 전송한다. 사용 중인 앱을 강제 종료하거나 저장 데이터·기억을 초기화하지 않는다. 따라서 기존 기억과 사용자 설정은 그대로 실험 조건에 포함된다. 전용 테스트 계정과 데이터에서 사용하고 실행 중 수동 대화와 섞지 않는다.

입력은 `id`, `prompt`만 갖는다. 시스템 프롬프트는 앱에서 조립한다. 컨텍스트·샘플링·임베딩 상주 정책도 앱 설정을 유지한다. 첫 실행과 연속 발화를 같은 입력으로 비교하고, 설정 변경은 별도 구현과 빌드로 분리한다.

기록에는 모델·임베딩·검색 자료 로딩, 임베딩 계산, 토큰 측정, 세션 생성·해제·교체, 입력 접두어 일치량, 첫 출력 이벤트, 답변 완료와 메모리 경고가 포함된다. 첫 출력 시간은 브리지 이벤트 발생까지이며 화면에 실제 그려지는 시각은 아니다. 이는 Swift 래퍼의 호출 관측이며 네이티브 캐시 바이트를 직접 측정하지 않는다.

구간 경계는 즉시 저장하고 주기 샘플은 메인 스레드와 독립된 큐에서 500밀리초마다 저장한다. 강제 종료 시 저장 전 마지막 샘플과 파일 색인 갱신 중 자료는 유실될 수 있다. 완료 이벤트나 명령 영수증이 없어도 검증된 부분 기록을 회수한다. 관측 최대 메모리는 샘플 중 최대치이며 실제 순간 최대치를 보장하지 않는다. 측정과 파일 저장 비용도 실제 앱 메모리·시간에 포함된다.


## 캐시 비교

제품 프롬프트로 비교할 때는 수동으로 만들어 둔 fixture를 고르지 않는다. 앱 빌드에 사용한
`dialogue-content.json`과 명시적인 대화 턴 파일을 함께 전달하면 공용 Swift
`DialoguePromptComposer`가 실제 시스템·사용자 입력을 만든다. 검색 결과에 따라 고정
접두부가 달라지는 것을 막기 위해 이 비교에서는 retrieval을 명시적으로 제외하며, 턴 사이
시스템 프롬프트 해시가 달라지면 실행 전에 실패한다.

```sh
uv run beolmuri-eval resource kv-cache \
  --config experiment.yaml --device DEVICE_ID --app APP_PATH --model-preinstalled \
  --content /path/to/dialogue-content.json --turns /path/to/turns.json
```

턴 파일은 `id`, `user_message`, `history`만 가진 배열 또는 JSONL이다. `history`의 각 원소는
`user`, `assistant` 문자열을 가진다. 실제 조립 결과와 콘텐츠·시스템 프롬프트 해시는 배치의
`inputs/prepared-fixture.jsonl`, `inputs/prompt-provenance.json`에 보존한다.

생성 설정의 `conversation_mode`를 다음 중 하나로 정한다.

- `fresh_per_input`: 요청마다 새 대화를 생성한다.
- `cached_full_prompt`: 앱과 동일한 Swift 캐시 세션을 유지한다. 각 행은 최신 이력·기억·질문을 포함한 완성된 입력이며, 이전 행 뒤에 자동으로 누적되지 않는다.

모델·입력 행·샘플링·4,096 컨텍스트를 동일하게 두고 모드만 바꿔 실행한다.
비교 명령에는 `--allow generation.conversation_mode`를 지정한다.
첫 발화는 초기 프리필이고 다음 발화부터 재사용 후보가 된다. 현재 실행기가
측정 창마다 앱을 다시 시작하므로 다른 창 사이의 캐시는 유지되지 않는다.

두 모드 모두 `first_response_seconds`와 `generation_elapsed_seconds`를 기록한다.
캐시 모드의 `matching_input_prefix_tokens`는 입력끼리의 접두부 일치량이다.
실제 네이티브 적중량으로 해석하지 않는다. 이 값과 별도로 원본 이벤트의
`cache_session_id`로 같은 세션 유지 여부를 확인한다. 원본 응답도 확인하여
바뀐 기억이 이전 값으로 남지 않는지 검토한다.

캐시 모드에서는 세션 C API가 제공하지 않는 KV 크기와 발화별 네이티브 TTFT를
`unsupported`로 남긴다. 네이티브 프리필 토큰 수·처리량은 API의 원래 의미로
보존하며, 재계산한 토큰 수라고 단정하지 않는다. 지원되는 측정값이 누락되면
해당 실행은 여전히 불완전한 결과다. 실제 기기 추론·속도 개선은 별도 실측 대상이다.
