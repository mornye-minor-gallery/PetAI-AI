# 대화 입력 구성

앱과 평가 워커는 `DialoguePromptComposer`를 공유한다. 캐릭터 원문·장면 선택,
EdgeMem 검색·저장, 도구 실행은 호출 측의 책임이다. Composer는 공급받은 자료를
배치하고 입력을 만든다. Author’s Note와 World Info의 검색·재귀·기간 효과를 공용 경로에 연결했다.

## 캐릭터 콘텐츠 공급

캐릭터 YAML(`id`, `name`, `persona`, `examples`)과 상황 YAML(`situation`,
`knowledge`)은 저장소 밖에서 작성한다. 긴 문장은 YAML의 `|`로 쓴다.
`scripts/dialogue/compile-content.py`가 두 파일을 `dialogue-content.json`으로
변환하고, 앱과 평가 워커는 공용 `DialogueContent`로 읽는다. Swift에는 YAML
파서나 캐릭터 원문을 넣지 않는다.

```sh
python scripts/dialogue/compile-content.py \
  --character /private-content/characters/sample.yaml \
  --situation /private-content/situations/daily.yaml \
  --output /private-content/generated/dialogue-content.json
```

평가 Python 환경에 설치된 PyYAML을 사용한다. 생성 JSON도 Git 밖에 둔다.
Unity iOS export는 환경변수 `PETAI_DIALOGUE_CONTENT`로 JSON의 절대경로를 받고,
EdgeLLMLab 빌드는 같은 이름의 Xcode 빌드 설정을 받는다. 원본 YAML 변경 후에는
변환기를 다시 실행한다. JSON은 앱 번들에 포함되므로 배포된 앱에서는 읽을 수
있는 콘텐츠이며, Git 비추적은 앱 내부 암호화를 뜻하지 않는다.

`DialogueContent.promptSet`은 페르소나·현재 상황·지식을 구역별로 조립하고,
`exampleDialogue`는 예시를 실제 대화 이력과 구분해 전달한다. 앱은 해당 파일의
이름을 사용하며 다른 캐릭터를 선택하면 `character_not_configured`를 보고한다.
기억은 콘텐츠 `id`로 범위를 나누고 기존 일반 대화의 기억을 자동 이관하지 않는다.
콘텐츠가 없거나 읽을 수 없으면 `persona_content_unavailable`이다.

임베딩 라우팅·도구·EdgeMem은 콘텐츠와 독립적으로 유지한다. `RoutedPersonaPromptSet`
직접 주입과 명시적 체크섬 로더는 별도 호출 측에서 사용할 수 있으나, 기본
레지스트리가 과거 연구 폴더를 탐색하는 일은 없다. 이름 삽입은 `{{char}}`를 쓴다.

## 배치와 모델 전달 형식

`DialoguePromptInput.insertions`로 본문·출처·위치·역할·순서를 전달한다.
현재 위치는 `beforeCurrent`, `afterCurrent`이며, 각 위치에서 `order` 오름차순,
동률이면 공급 순서를 따른다. ID는 비어 있지 않고 고유해야 하며 `nameRule`,
`currentMessage` 등 기본 구역 ID와 겹칠 수 없다. 빈 본문은 제외 이유를 기록한다.

`PreparedDialogue.modelInput`의 형식은 `systemAndUserText`이다. 삽입 항목의 역할은
원본 설정을 보존하는 메타데이터이며 모든 삽입 항목은 실제로 사용자 입력 문자열
안에 들어간다. `prompt_trace.insertions`의 `requestedRole`과 `deliveredRole`로
이 차이를 확인한다. 별도의 네이티브 system 메시지를 추가하는 기능이 아니다.

기존 이름 규칙도 같은 배치 코드를 사용한다. 일반 삽입은 기존 규칙을 제거하지
않으므로, 규칙 이동과 추가 재상기는 서로 다른 설정이다. 노트·기억·예시는 실제
대화 이력에 저장하지 않는다.

## 세션 스냅샷

`RoutedPersonaSessionContext`는 최근 요청 20턴과 누적 순번을 관리한다. 정상
완료·취소·오류 상태와 실제로 보인 답변 조각은 `ChatTurn`에 기록한다. 사용자
발화는 요청 접수 시 보이는 순번을 올리고, 답변은 첫 글자가 나올 때 메시지
순번을 한 번만 올린다. 완료된 교환 횟수는 별도로 유지하며 취소·오류로 늘지
않는다. 이력을 잘라도 누적 순번은 유지한다.
완료된 교환만 기록하면 실패한 사용자 발화가 다음 대화에서 사라지고, 메시지
20개로 자르면 답변이 없는 요청이 보관 단위를 흐트러뜨린다. 따라서 요청을
보관 단위로 삼고 보이는 순번과 완료 횟수를 분리한다.

```swift
let snapshot = try session.beginRequest(requestID: requestID, userMessage: userMessage)
// snapshot.history와 snapshot을 같은 DialoguePromptInput에 전달한다.
// 생성된 글자는 appendAssistantText로 누적한다.
try session.appendAssistantText(requestID: requestID, text: visibleChunk)
try session.finishRequest(requestID: requestID, status: .completed,
    assistantMessage: visibleResponse, worldInfo: worldInfoTransaction)
```

스냅샷의 `currentUserMessageNumber`, `currentMessageNumber`는 현재 사용자 발화를
포함한 위치다. 취소·오류로 답변이 없더라도 사용자 발화는 다음 프롬프트에 남는다.
부분 답변은 중단 상태를 표시하지만 월드 정보 상태와 장기기억 저장 대상이 되지
않는다. 평가 워커는 완료된 교환을 원자적으로 넣는 기존 `snapshot/commit` 경로를
계속 사용한다. 버전 2 체크포인트는 중단 턴을 보존하며 버전 1을 읽을 수 있다.

`appendExchange`는 완료된 평가 이력 공급에 사용한다. 실제 앱에서는 요청 ID로
스트리밍과 종료를 소유하며, 오래된 요청의 토큰과 종료는 거부한다. 앱 재실행을
넘는 최근 문맥은 `Application Support/PetAI/ChatSession/recent-turns.json`에
저장한다. 로그인 계정이 아니라 기기를 기준으로 공유하며 백업에서 제외한다.
같은 기기의 여러 계정이 한 캐릭터와의 대화를 이어 쓰는 정책이므로 계정별 파일을
만들지 않는다. 그 대신 새 계정으로 로그인해도 이전 대화를 볼 수 있다는 점을
감수하며, 다른 기기와 자동으로 동기화하지 않는다.
요청을 받아들일 때 사용자 발화를 먼저 저장하고 완료·취소·오류 때 확정된 턴을
다시 저장한다. 생성 중 토큰은 파일에 쓰지 않으므로 강제 종료 뒤에는 해당 요청을
답변 없는 중단 턴으로 복원한다. 정상 종료된 부분 답변은 보존한다. 최근 20턴 밖으로
밀린 비장기기억 발화는 이 파일에 남지 않는다. 저장 실패를 빈 문맥으로 숨기지
않으며, 월드 정보 준비 결과는 답변이 정상 완료될 때만 반영한다.
현재 요청이 최근 20턴의 한 자리를 차지하므로 프롬프트에는 이전 대화 최대 19턴을
넣는다. 이 최근 턴들의 요청 ID는 EdgeMem 검색에서 제외한다. 밖으로 밀려난 P·E
기억은 삭제하지 않으며, 관련성이 있으면 다음 검색부터 다시 가져올 수 있다.

## 토큰 예산

Unity의 기본 캐릭터 대화와 평가 기본 YAML은 실제 측정기를 공급해 토큰 예산 경로를 사용한다.

```swift
let prepared = try await DialoguePromptComposer.prepare(
    input: input, policy: policy, tokenBudget: budget, measurer: measurer)
```

- `DialogueTokenMeasuring.countTokens`: 현재 모델의 토크나이저로 본문을 센다.
- `measureInput`: 네이티브 템플릿과 이미 반영된 토큰까지 정확히 한 번 센다.
- `DialogueTokenBudget.memoryTokens`: 기억 설명 헤더·줄바꿈을 포함한 기억 구역 예산.
- `contextTokens`, `outputTokens`: 실제 런타임 한도와 출력 예약량.

기억은 검색 순위대로 전체 항목 단위로 선택하며, 후보를 추가한 구역 전체를 다시
측정한다. 항목별 토큰 수는 문자열 경계에서 단순 합산되지 않을 수 있다. 기억
예산 0은 기억을 넣지 않는 설정이다. 최종 입력이 `contextTokens - outputTokens`를
넘으면 구성 오류를 반환한다. 모델에 보내기 직전 몰래 잘라내거나 바이트 계산으로
대체하지 않는다. World Info 선택 예산은 해당 엔진에서 별도로 관리한다. 재귀 검색도 같은 WI 선택 예산을 사용한다.

`SLMConfiguration.production.dialogueBudget`의 초기 정책은 전체 8,096·기억 2,048·
출력 1,024토큰이다. 기억 2,048은 최대 입력 7,072 안에 포함되며, 출력과 기억을
최대한 채우는 목표가 아니다. 품질 튜닝으로 결정된 최적값도 아니다. 앱 엔진의
`maxNumTokens`와 실제 캐릭터 대화의 `maxOutputTokens`에도 같은 값을 전달한다.

파트별 독립 토큰 수는 `trace.tokenBudget.sections`에 ID·역할·토큰 수로 기록한다.
캐릭터, 장면, 프로필, 이름 규칙, 출력 형식, 이력, 기억, 현재 발화, 삽입 노트를
구분한다. 이 수치는 각 본문을 따로 센 참고값이며 합계가 전체 입력 토큰 수는 아니다.
네이티브 템플릿과 구분자를 포함한 `inputTokens`만 전체 상한 판정에 사용한다.
`availableOutputTokens`는 문맥에 남은 공간이고 실제 출력 상한은
`reservedOutputTokens`다. 파트별 추가 상한과 자동 절단 정책은 도입하지 않았다.

바이트 방식의 동기 호출은 기존 연구 YAML, 페르소나 비활성 경로, EdgeLLMLab의
기억 전용 입력에 남는다. 해당 경로는 `memory.promptByteBudget`을 사용한다.
도구 생성과 기존 바이트 실험의 출력 상한 4,096은 별도 소비자의 설정으로 유지한다.
토큰 경로의 `memoryByteBudget`은 없으며 바이트 숫자를 토큰으로 재해석하지 않는다.

네이티브 측정은 `LiteRTLM.Engine.countTokens`와
`measureTextPrompt(systemPrompt:userPrompt:thinkingEnabled:)`를 사용한다. 측정과
실제 대화 생성이 같은 thinking 문맥과 필터 설정을 사용하며, 도구 템플릿과 임의
추가 문맥은 이 텍스트 경로에 포함하지 않는다. 임시 conversation의 초기화 비용은
발생할 수 있지만 활성 conversation은 변경하지 않는다.

`LiteRTLMRuntime.prepareDialogue`는 측정부터 실제 conversation 준비까지 직렬화한다.
준비 중에는 `preparingInput` 상태를 표시하고 다른 생성·초기화·해제를 거부한다.
취소를 확인한 뒤 생성으로 넘어가며, 같은 conversation의 답변 재시도도 현재 KV를
포함해 입력·출력 예산을 다시 검사한다. 측정/예산 실패는 오류로 전달한다.

평가 Swift 워커는 JSONL `measurement_required`로 본문 또는 최종 입력 측정을
요청한다. Python은 같은 모델의 토큰 수만 반환하며 기억 선택은 Swift에 남는다.
요청 ID·측정 순번을 확인하고 실패도 응답으로 반환하므로 다음 요청과 섞이지 않는다.
기본 YAML의 `prompt_budget`을 제거한 기존 연구 구성은 바이트 재현 경로다.

## 확인 방법

- `swift test --package-path ios/EdgeLLM`: 기존 24개 입력 동등성, 배치·세션·예산 경계.
- `bash scripts/test-litertlm-tokenization.sh`: C stub으로 UTF-8 전달, 결과 해제, 실패 확인.
- Swift 평가 워커의 `prepare`는 `insertions`를 받고 `input_format`, `session_clock`,
  `prompt_trace`를 반환한다. 고정 이력 40왕복을 주면 20턴, 즉 40개 메시지를 유지하면서
  현재 사용자 번호는 41, 현재 전체 메시지 번호는 81로 보고한다.

C stub 검사는 실제 모델의 토큰 수를 검증하지 않는다. iOS 타입 검사와 프레임워크
심볼 확인도 실제 기기의 생성·메모리·성능 검증을 대체하지 않는다.

### Author’s Note

`AuthorsNoteResolver`는 설정 상속과 활성 주기를 결정하고, `DialoguePromptComposer`는
그 결과를 배치·직렬화·계측한다. 앱은 `SLMConfiguration.authorsNote`, 평가 실행부는
variant의 `authorsNote`로 같은 `AuthorsNoteSettings`를 공급한다. 기본값 `nil`은 노트를
추가하지 않는다. 임의의 말투 지시나 최적화된 문구를 기본값으로 채택하지 않았다.

- `chat`의 필드 → `defaults`의 필드 → 기본값 순으로 해석한다. 빈 문자열은 명시적인 재정의다.
- 기본값은 빈 본문, 주기 1, `in-chat`, 깊이 4, 논리 역할 `system`이다.
- 주기 0은 비활성, 1은 항상 활성, 그 외는 현재 사용자 메시지 번호가 주기의 배수일 때 활성이다.
- 현재 캐릭터의 `character.enabled`가 참이면 `replace`/`before`/`after`로 본문을 합성한다.
  캐릭터 선택은 호출자의 책임이다. 주기가 비활성인 턴에는 캐릭터 노트도 넣지 않는다.
- `in-chat` 깊이 0은 현재 발화 뒤, 1은 바로 앞, 2부터는 보존된 대화 메시지 사이에 넣는다.
  깊이가 이력보다 크면 이력 맨 앞에 둔다. 기억·다른 삽입 항목은 깊이 계산에 포함하지 않는다.
- `before-system`/`after-system`은 조립된 시스템 본문의 앞/뒤다. SillyTavern의
  `BEFORE_PROMPT`/`IN_PROMPT`에 대응하지만, 이 프로젝트의 시스템 본문에는 응답 계약도 포함된다.
- `prompt_trace.authorsNote`에는 적용된 설정·주기 상태·누적 번호가 남는다.
  삽입 추적에는 요청 역할과 실제 전달 역할이 각각 기록된다. 노트도 전체 입력 예산과 파트별 계측에 포함된다.

기준 소스는 [SillyTavern 고정 커밋](https://github.com/SillyTavern/SillyTavern/tree/06bde939fb1e9c4c8d8641d810f0a916b5bce127)의
`authors-note.js`에 있는 `loadSettings`/`setFloatingPrompt`, `script.js`의 `doChatInject`다.
브라우저 기능 전체를 복제하는 포팅이 아니라, 위 동작 계약을 Swift로 구현한 것이다.
원본 함수에서 생성한 기대값은 테스트 리소스에 고정되어 있다.

```sh
swift test --package-path ios/EdgeLLM
```

원본과 다른 연결 규칙도 명시한다. LiteRT-LM에는 시스템 메시지 하나와 사용자 메시지
하나를 보낸다. 이력 중간 노트의 논리 `system` 역할은 사용자 문자열 안의 배치이며,
실제 시스템 메시지를 추가하지 않는다. 세션 번호는 잘린 이력 길이가 아닌 누적 번호를
사용하고, 앱에서는 성공한 응답만 확정한다. 취소·실패·응답 형식 재시도는 번호를 늘리지
않는다. 도구가 만든 가시 응답도 대화 이력과 누적 번호에 포함한다.

`allowWorldInfoScan`과 활성 여부는 World Info 검색의 입력이다. 활성 턴에는
본문이 비어 있어도 World Info가 노트 앞뒤 내용을 합성할 수 있도록 상태를 보존한다.
World Info의 검색·노트 합성을 연결했다. 노트는 논리 역할과 실제 전달 역할을 구분한다.
브라우저의 continue/impersonate 생성 자체를 추가하지 않으며, 해당 문자열은 호스트가
전달하는 생성 트리거 필터로 사용할 수 있다.

### World Info

`WorldInfoEngine`과 `WorldInfoPromptProjection`은 앱·평가의 공용 Swift 경로다.
앱의 `SLMConfiguration.worldInfo`, 평가 variant의 `worldInfo`가 같은 설정을 사용한다.
기본값은 nil이며 콘텐츠·최적 튜닝값을 임의로 활성화하지 않는다. EdgeMem, 장면 라우터,
도구 실행은 각자 기존 책임을 유지한다.

처리: 자료집 선택 → 기간·캐릭터·트리거 필터 → 키/정규식/외부 활성화 → 그룹 → 확률
→ 본문 매크로 → WI 예산 → 재귀/최소 활성화 반복 → 후처리 → 목적지 조립 → 전체 토큰 검사.

| 모듈 | 책임 |
| --- | --- |
| WorldInfoSettings / Entry / Rules | 고정·비율·상한 예산, 검색·항목 설정 |
| WorldInfoLibrary / Lorebook | 원본 JSON 입출력, 수정, 범위별 자료집 선택 |
| WorldInfoEngine / Matching / Groups | 재귀·최소 활성화, 그룹 점수·우선·가중 추첨, 확률 |
| WorldInfoTemporalRules | Sticky/Cooldown/Delay 준비와 다음 상태 계산 |
| WorldInfoText | Swift 매크로 파서·평가기와 네이티브 정규식 어댑터 |
| WorldInfoVectorSearch | 작성된 로어북의 로컬 의미 검색; EdgeMem 자료와 분리 |
| WorldInfoPromptProjection | 캐릭터·노트·깊이·예시·아웃렛 목적지 |
| WorldInfoTransaction | 성공 응답과 함께 확정할 기간/변수/자동화 결과 |

`scanDepth`는 현재 사용자 발화를 포함한 메시지 수이며 기본 2, 최대 1000이다.
키는 OR, 보조 키는 AND_ANY/AND_ALL/NOT_ANY/NOT_ALL이다. `constant`도 비활성·기간·
필터·예산을 지킨다. `order`는 큰 값부터 선택하고 목적지 안에서는 역순 출력한다.
정규식 키가 유효하면 대소문자/단어경계 설정보다 우선한다. 일반 단어경계는 원본의
ASCII 규칙이며 한국어 형태소 분석이 아니다.

`rules`는 재귀, 최대 반복, 최소 활성화 수, 최대 확장 깊이, 그룹 점수, 비율 예산,
토큰 상한과 벡터 설정을 받는다. 항목의 `rules`는 재귀 제외·전파 중지·지연 단계,
확률, 그룹·가중치·우선권, Sticky/Cooldown/Delay, 캐릭터/태그 포함·제외, 트리거,
추가 검색 필드, 깊이/역할, 아웃렛, 자동화 ID와 후처리를 받는다. 정확한 JSON 필드는
`ai/beolmuri-eval/schemas/evaluation.schema.json`을 따른다. 알 수 없는 설정은 오류다.

`library`는 원본 JSON 문자열을 이름별로 담는 `books`, `global` 목록, 캐릭터 이름별
`characters` 목록, 선택적인 `chat`/`persona`, `strategy`를 받는다. 전략은 even,
characterFirst, globalFirst다. 채팅·페르소나 우선순위를 예산 선택까지 보존한다.
직접 지정한 `entries`는 자료집 선택 뒤에 추가한다. 원본 파일 수정 API는 알 수 없는
실행 필드를 거부하고, 주석·표시 순서·extensions 등 메타데이터는 보존한다.

`position`은 before-character, after-character, before-note, after-note, in-chat,
before-examples, after-examples, outlet이다. 같은 depth/role은 한 블록으로 묶는다.
예시 대화는 `DialoguePromptInput.exampleDialogue` 앞뒤에 배치한다. 실제 LiteRT-LM
전달 형식은 여전히 system+user 문자열이며 in-chat의 요청 역할은 추적 메타데이터다.
아웃렛은 자동 삽입하지 않고 작성된 프롬프트/노트의 `{{outlet::이름}}`으로 참조한다.
사용자 발화·이력·회수 기억의 매크로는 실행하지 않는다.

토큰은 실제 측정기로 센다. WI 예산은 EdgeMem과 별개다. `budgetPercent`가 있으면 전체
컨텍스트의 비율로 WI 예산을 계산하고 `budgetCap`으로 제한한다. 원본처럼 누적 값이
예산과 같아도 제외하고 작은 항목으로 다시 채우지 않는다. `ignoreBudget`는 WI 예산만
우회한다. 최종 입력과 출력 예약을 합친 전체 상한은 항상 검사하고 초과 시 오류다.

기간 기준은 잘린 최근 이력 길이가 아니라 누적 메시지 번호다. 준비·검색·취소는 상태를
바꾸지 않으며 앱은 보이는 답변이 성공한 뒤 한 번만 commit한다. 동일 요청 재시도는
같은 난수 선택을 재현하고, 성공한 턴 다음에는 앱 seed를 전진시킨다. 기간 상태와
변수는 현재 대화 세션에 속하며 앱 재시작 후 디스크 복원을 추가하지 않았다.

벡터 설정을 켠 앱은 최근 N개 메시지로 query embedding, 로어북 본문으로 document
embedding을 만들고 코사인 유사도·상한으로 선택한다. 초기 query=2/최대5/threshold=.25는
원본 확장 기본값이지 제품 최적값이 아니다. 현재 문서 벡터는 요청마다 계산하며 지속
인덱스는 없다. 평가 worker는 명시적인 vectorMatches fixture를 받으며 자체 임베딩 추론을
하지 않는다. 게임 입력·성공 후 관찰 이벤트는 `WorldInfoSettings`와 `WorldInfoEngine`에서 정의한다.

추적에는 매칭 키, 선택/탈락 이유, 후보 토큰, 목적지와 삽입 여부가 들어간다.
선택됐어도 비활성 노트·빈 내용·아웃렛이면 실제 입력과 다르다. 최종 블록 토큰은
`tokenBudget.sections`, 다음 상태는 `world_info_transaction`에서 확인한다.

### 원본 대조와 호환 범위

원본: SillyTavern `06bde939fb1e9c4c8d8641d810f0a916b5bce127`.
테스트 리소스에는 원본 검색·기간·그룹·정규식·데코레이터 함수의 기대값이 포함되어 있다.

```sh
swift test --package-path ios/EdgeLLM
```

선택/본문 대조 74건 중 73건은 원본과 같고, 중복 그룹 제거 한 건은 원본의
`splice(-1,1)`이 무관한 후보를 지우는 버그를 고친 결과를 별도 검증한다. 비교 측정기는
UTF-16 길이이며 모델 품질이나 실제 토큰 정확도의 증거가 아니다.

이식 범위는 World Info 엔진과 네이티브 연결이다. 브라우저 UI·플러그인 실행기를
통째로 이식했다는 뜻은 아니다. 구체적 차이는 다음과 같다.

- 매크로: Swift 파서가 중첩·조건 분기·블록·변수 연산을 처리한다. 원본의 기본 엔진처럼
  텍스트 순서대로 실행하며 선택되지 않은 조건 분기는 상태를 바꾸지 않는다. `pick`은
  UTF-16 해시와 ARC4를 사용한다. 시간·난수·카드·대화 메타데이터는 호스트 입력이다.
  알 수 없는 매크로와 잘못된 인자는 오류이며, 실패 시 변수는 커밋하지 않는다.
  이는 원본 브라우저의 경고 후 원문 유지·부분 상태 반영과 의도적으로 다르다.
- 정규식: Foundation 어댑터가 g/i/m/s/u/y, 캡처 치환, ASCII 문자 집합·단어 경계,
  줄바꿈·끝 앵커를 처리한다. 글로벌→허용된 프리셋→허용된 캐릭터 순서로 설정을 적용한다.
  위치·편집 여부·깊이·화면/프롬프트 조건, 캡처에서 제거할 문자열, 검색식 매크로 이스케이프를 지원한다.
  비ASCII 대소문자 무시, u 없는 보충 평면 문자, 역참조·Unicode 속성·가변 길이 lookbehind는
  명시적 오류다. 전체 ECMAScript 정규식 호환을 주장하지 않는다. 동기 정규식 중간 취소는 없다.
- 가져오기: 네이티브 JSON, 캐릭터 책, Agnai·Risu·Novel 형식과 PNG의 ccv3/chara/naidata를 읽는다.
  JSON·PNG 경로는 하네스와 world-info CLI에서 같은 Swift 변환기로 전달된다.
  카드 자체 읽기는 `DialogueCharacterCard`, 책 편집·내보내기는 네이티브 JSON을 사용한다.
- 벡터: 변경된 내용만 다시 임베딩하고 파일에 원자적으로 저장한다. 앱은 모델·토크나이저
  내용 해시와 전처리 버전을 인덱스 식별자에 포함한다. 평가의 벡터 매칭 입력은 여전히 명시적 fixture다.
- 이벤트: 외부 활성화 입력과 성공 후 automation ID를 제공한다. 임의 브라우저 callback,
  Quick Reply/slash 실행기, Unity 게임 진행 변경 핸들러는 제공하지 않는다.
- 메모리 상태: 누적 시계와 성공 commit을 사용하는 앱 수명주기로 매핑했다.
  원본 이력 삭제/수정 UI 및 채팅 외부 변수 저장소는 별도 기능이다.
- 역할: 요청 역할과 실제 system/user 텍스트 전달 역할을 구분한다.

출처와 원본 AGPLv3는 `third_party/sillytavern/`에 보존한다. 이 문서는 결합된 앱의
배포 라이선스 검토를 대신하지 않는다. 단위 테스트·타입 검사는 기기 실행 증거가 아니다.

### 네이티브 텍스트 설정과 비교 테스트

텍스트 처리는 Swift로 실행한다. 원본 JS와 대조한 합성 입력·기대값은 테스트 리소스에 있다.
`DialoguePromptInput.authoredText`와 평가 YAML의 `authoredText`가 동일한 설정을 받는다.
`runtime`은 `nowMilliseconds`, `utcOffsetMinutes`, `locale`, `chatID`, 카드 필드와
모델 메타데이터를 제공하고, `regex`는 global/preset/character 설정을 제공한다.
노트만 사용해도 변수를 `world_info_transaction`으로 반환해 성공한 응답과 함께 저장한다.

평가는 시간 매크로를 사용할 때 고정 `nowMilliseconds`를 설정해야 한다. 앱은 요청 준비 시
현재 시각을 한 번 제공한다. 날짜 포맷은 명시된 Moment 토큰을 Foundation으로 변환하며,
지원하지 않는 토큰은 오류다. 상대 시간 문구는 현재 영어 기본 규칙만 제공한다.
브라우저 자동화·앱 밖 전역 변수 저장·응답 스트리밍 후처리는 이 텍스트 모듈의 범위가 아니다.

```sh
swift test --package-path ios/EdgeLLM
```

원본 버전과 이식 범위는 [출처 공지](../../third_party/sillytavern/NOTICE.md)에 기록한다.

### 외부 반응풀 리소스

`DialogueContent.retrieval`의 `reactions`와 `worldLore`로 독립적으로 활성화합니다. `dialogue-content.json`과 같은 디렉터리에 `reaction-frames.json`, `reaction-vectors.f32`, `dialogue-lore.json`을 둡니다. 랩 빌드는 `PETAI_DIALOGUE_CONTENT` 파일의 동반 자료를 함께 복사합니다. 캐릭터 자료는 호출 측에서 준비합니다.

`ReactionFrameIndex`는 예시 벡터를 한 번 로드하고 매 발화마다 최근 3개 메시지의 질의 벡터로 최상위 반응 하나를 선택합니다. `DialogueRetrievalResources`는 선택한 목표·응답 형태·대화 예시 한 쌍을 World Info의 깊이 0 배치로 전달합니다. 세계관은 키워드 검색과 별도 예산을 유지합니다. 앱의 도구 라우팅 이후 일반 대화 경로에서만 호출하며 EdgeMem 회수 경로와 독립적입니다. 인덱스 누락·벡터 손상·임베딩 식별자 불일치는 오류로 노출합니다.
