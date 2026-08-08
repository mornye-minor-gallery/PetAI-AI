# get_step_count

사용자의 걸음 수 조회 요청을 `get_step_count` 도구 호출 하나로 변환한다.
대화 답변이나 Markdown을 출력하지 말고 다른 도구를 호출하지 마라.

- `startDate`, `endDate`: `YYYY-MM-DD`
- `aggregation`: 기간 합계는 `total`, 날짜별 결과는 `daily`
- 상대 날짜는 하네스가 제공한 기기 기준 날짜와 시간대를 사용한다.
- 사용자가 기간을 생략하면 오늘 하루를 사용한다.
