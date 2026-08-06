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

## 제작 순서

1. 목표 `split`, `route_id`, `difficulty`, `domain`, `style_tags`를 먼저 결정한다.
2. 생성 세션에 해당 목표와 `routes.v1.json`의 필요한 계약만 제공한다.
3. 생성 세션은 목표 수량보다 많은 후보를 만든다.
4. 중복·금칙 조건을 기계적으로 검사할 수 있는 단계에서 먼저 제거한다.
5. 독립 검증 세션에는 목표 Route ID를 숨기고 전체 라우트 정의와 후보 문항만 제공한다.
6. 검증 세션은 정확히 하나의 Route ID 또는 `AMBIGUOUS`를 반환한다.
7. 검증 Route ID가 제작 Route ID와 정확히 같은 후보만 채택한다.
8. 채택 레코드는 `dataset.schema.json`을 통과해야 한다.
9. split 간 의미 중복 검사를 수행하고 단순 패러프레이즈를 제거한다.
10. 파일을 동결할 때 레코드 수와 SHA-256을 manifest에 기록한다.

## 난이도 계약

### direct

목표 라우트의 핵심 의도가 현재 사용자 발화에 직접 드러난다. 단순 키워드만 나열한 문장이나 라우트 설명을 그대로 옮긴 문장은 허용하지 않는다.

### natural

실제 펫 육성 일상 또는 서사 대화에서 자연스럽게 나올 수 있는 표현이다. 핵심 의도는 명확하지만 route label의 설명 문구와 표면적으로 다를 수 있다.

### neighbor

인접 라우트와 소재나 단어를 공유하지만 하나의 명시적 단서로 정답이 구분된다. 인접 라우트도 정답이 될 수 있는 복수 의도 문장은 폐기한다.

### general

어떤 전문 라우트에도 해당하지 않는 일반적인 발화다.

### hard_negative

전문 라우트의 키워드·소재·표현 일부를 포함하지만 실제 요청 의도는 해당 전문 라우트가 아니다.

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

검증기는 설명문 없이 다음 중 하나만 반환한다.

```text
FIRST_SIGNAL
```

```text
AMBIGUOUS
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
