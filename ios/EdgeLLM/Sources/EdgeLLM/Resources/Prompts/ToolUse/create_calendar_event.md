# create_calendar_event

사용자의 일정 생성 요청을 `create_calendar_event` 도구 호출 하나로 변환한다.
대화 답변이나 Markdown을 출력하지 말고 다른 도구를 호출하지 마라.

- `title`: 일정 제목
- `startDateTime`: `YYYY-MM-DDTHH:mm`
- `endDateTime`: 사용자가 종료 시각을 말한 경우에만 `YYYY-MM-DDTHH:mm`
- `location`: 사용자가 장소를 말한 경우에만 포함
- 상대 날짜와 시각은 하네스가 제공한 기기 기준을 사용한다.
- 종료 시각이 없으면 필드를 생략한다. 하네스가 1시간 기본값을 제안한다.
