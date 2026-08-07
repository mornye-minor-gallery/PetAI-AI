status:: active

# FacetRouteBench 데이터 제작 계약

main:: [[../SPEC]]
route_contract:: ./routes.v1.json
dataset_schema:: ./dataset.schema.json

## 목적

정답 Route ID가 하나로 명확하고 표현이 충분히 다양한 Authoring, Dev, Frozen, Context Challenge 데이터를 사람의 필수 보정 없이 생성한다.

## 고정 실행 조건

- 인터페이스: Codex CLI 로컬 어댑터
- 생성 모델: `gpt-5.6-sol`
- 생성 reasoning effort: `medium`
- 검증 모델: `gpt-5.6-sol`
- 검증 reasoning effort: `medium`
- 생성과 검증은 공유 대화 기록이 없는 독립 세션으로 실행한다.

모델 버전 또는 reasoning effort가 바뀌면 동일 batch에 섞지 않고 새 batch ID를 발급한다.

초기 후보 oversample factor는 `1.5`로 고정한다. 검증 후 부족한 `authoring_task_id × domain` 셀에는 부족 수량과 같은 수의 후보를 동일한 고정 프롬프트·계약으로 다시 생성한다. 이 rejection sampling은 최대 5 round까지만 수행하며 round 사이에 factor, 프롬프트 또는 계약을 수정하지 않는다. 이후에도 목표 수량을 채우지 못하면 해당 제작을 실패로 기록한다.

## 제작 순서

1. 목표 `split`, `route_id`, `difficulty`, `domain`을 먼저 결정한다.
2. 생성 세션에 해당 목표, `persona_core.md` 원문과 `routes.v1.json`의 필요한 계약을 제공한다. Scene Router와 Scene Card는 제공하지 않는다.
3. 생성 세션은 목표 수량보다 많은 후보를 만든다.
4. 중복·금칙 조건을 기계적으로 검사할 수 있는 단계에서 먼저 제거한다.
5. 정본 검증 세션에는 목표 Route ID를 숨기고 `persona_core.md`와 후보 문항만 제공한다.
6. 정본 검증은 정체·관계·설정·지식 경계와 대화 자연스러움의 일치 여부를 반환한다.
7. 정본 검증을 통과한 후보만 독립 라우트 검증으로 보낸다.
8. 독립 라우트 검증 세션에는 목표 Route ID를 숨기고 전체 라우트 정의와 후보 문항만 제공한다.
9. 라우트 검증 세션은 정확히 하나의 Route ID 또는 `AMBIGUOUS`를 반환한다.
10. 검증 Route ID가 제작 Route ID와 정확히 같은 후보만 채택한다.
11. 셀별 채택 수가 목표보다 부족하면 동일한 `split`, `route_id`, `difficulty`, `domain`으로 부족 수량만 다시 생성하고 4~10단계를 반복한다.
12. 11단계는 최대 5 round이며 결과를 보고 생성 프롬프트나 계약을 고치지 않는다.
13. 채택 레코드는 `dataset.schema.json`을 통과해야 한다.
14. split 간 의미 중복 검사를 수행하고 단순 패러프레이즈를 제거한다.
15. 파일을 동결할 때 레코드 수와 정본·프롬프트·계약의 SHA-256을 manifest에 기록한다.

## 난이도 계약

### direct

목표 라우트의 핵심 의도가 현재 사용자 발화에 직접 드러난다. 단순 키워드만 나열한 문장이나 라우트 설명을 그대로 옮긴 문장은 허용하지 않는다.

### natural

사용자와 엘레나가 함께 생활하고 대화하며 친구로 가까워지는 일상 또는 서사에서 자연스럽게 나올 수 있는 표현이다. 핵심 의도는 명확하지만 route label의 설명 문구와 표면적으로 다를 수 있다.

## Domain 계약

- `shared_daily`: 함께하는 식사, 외출, 휴식, 방 꾸미기, 취미, 공부, 고민과 감정 교류
- `narrative`: 귀환, 쌍둥이, 첫 교신, 나침반과 연결된 서사
- `mixed`: 일상과 서사 단서가 함께 있는 대화

Domain은 생성 모델이 선택하지 않는다. Authoring 계획에서 고정한 값을 생성 요청에 제공하고 결과 레코드에도 그대로 기록한다.

### neighbor

인접 라우트와 소재나 단어를 공유하지만 하나의 명시적 단서로 정답이 구분된다. 인접 라우트도 정답이 될 수 있는 복수 의도 문장은 폐기한다.

### general

어떤 전문 라우트에도 해당하지 않는 일반적인 발화다.

### hard_negative

전문 라우트의 키워드·소재·표현 일부를 포함하지만 실제 요청 의도는 해당 전문 라우트가 아니다.

Authoring GENERAL hard negative는 19개 전문 Route ID를 경계 대상으로 먼저 고정한다. 각 경계 태스크는 6개 또는 7개를 생성하며 전체 120개를 이룬다. 생성자는 경계 Route ID와 정의를 보지만, 정본·블라인드 검증기는 기존처럼 제작 라벨을 보지 않는다. `~해주지 마`, `~를 묻는 건 아니고`처럼 경계를 인위적으로 노출하는 부정문은 허용하지 않는다.

### context_dependent

마지막 사용자 발화만 보면 모호할 수 있지만 이전 공개 대화를 포함하면 목표 라우트 하나가 명확해진다. Context Challenge에서만 사용한다.

## 표현 다양성

한 라우트와 난이도 안에서도 다음 표현을 분산한다.

- 짧은 모바일 채팅체
- 자연스러운 일상 대화
- 감정이 섞인 표현
- 서사적 표현
- 존댓말과 반말
- 생략과 완곡 표현
- 의미를 훼손하지 않는 소량의 오타·띄어쓰기 오류

동일한 문장 골격에서 명사만 교체한 후보를 여러 split에 나누지 않는다.

## 독립 검증 출력 계약

정본 검증기는 `candidate_id`, `accepted`, `reason_code`를 반환한다. `accepted=true`일 때 `reason_code`는 반드시 `NONE`이다. 정본 검증기는 목표 Route ID를 보지 않는다.

정본 검증과 블라인드 라우트 검증은 생성 세션 및 서로와 세션을 공유하지 않는다.

검증기는 배치의 각 `candidate_id`마다 설명문 없이 다음 중 하나를 구조화 JSON으로 반환한다.

```json
{"candidate_id":"candidate-...","predicted_route_id":"FIRST_SIGNAL"}
```

```json
{"candidate_id":"candidate-...","predicted_route_id":"AMBIGUOUS"}
```

허용 Route ID는 `routes.v1.json`의 `route_order`와 정확히 같아야 한다. 공백 제거 이후 허용 값 하나와 정확히 일치하지 않으면 검증 실패로 처리한다.

## 채택 금지 조건

- 정답이 두 개 이상 가능한 문항
- 현재 입력만으로 정답을 알 수 없는 단일 턴 문항
- 목표 라우트 설명을 사실상 복사한 문항
- 사용자 발화가 아니라 캐릭터의 답변을 묻는 문항
- 외부 사실 확인이 정답에 필요한 문항
- 인접 라우트와 구분할 단서가 없는 neighbor 문항
- Authoring, Dev, Frozen 사이의 단순 패러프레이즈
- 검증 결과가 제작 Route ID와 불일치한 문항
- 정본 페르소나와 정체·관계·설정·지식 경계가 충돌하는 문항
- 실제 사용자 대화로 보기 어려운 문항

채택 금지 문항을 사람이 고쳐서 되살리지 않는다.
