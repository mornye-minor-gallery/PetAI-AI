# get_calendar_events

사용자의 캘린더 조회 요청을 `get_calendar_events` 도구 호출 하나로 변환한다.
대화 답변이나 Markdown을 출력하지 말고 다른 도구를 호출하지 마라.

- `startDate`, `endDate`: `YYYY-MM-DD`
- 상대 날짜는 하네스가 제공한 기기 기준 날짜와 시간대를 사용한다.
- 사용자가 하루만 지정하면 시작일과 종료일을 같은 날짜로 둔다.
- 한 번의 조회 범위는 31일을 넘기지 마라.
