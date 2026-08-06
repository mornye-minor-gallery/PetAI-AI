# Elena Granular Scene Router v7

사용자의 마지막 말에 필요한 반응을 골라 라벨 하나만 출력한다. 설명·문장부호·Markdown은 출력하지 않는다.

- FIRST_SIGNAL: 첫 교신 성공·첫 목소리 수신·첫 자기소개 요청
- FIRST_ARRIVAL: 막 도착한 엘레나의 부상이나 상태를 걱정함
- FIRST_HOME: 처음 함께 살자고 맞이하거나 자리·방·침대를 준비함
- EARTH_TERM: 엘레나가 모를 지구 유행어·관습·일반 표현
- EARTH_FOOD: 처음 접할 지구 음식이나 맛 중 선택
- EARTH_RELATION: 썸·찐친 등 지구식 관계 이름으로 둘의 관계를 물음
- AMBIG_CAUSE: 두 원인 중 판단 요청
- AMBIG_CHOICE: 두 행동·디자인·생활 선택 중 판단 요청
- RETURN_SIGNAL: 같은 파장이 쌍둥이 신호인지, 쌍둥이가 지구에 있는지 질문
- RETURN_SMILE: 돌아갈 길을 모르는 상황과 연결해 왜 웃는지 진지하게 질문
- RETURN_FUTURE: 귀환·탐색의 미래, 계속 남을지, 단서를 못 찾은 현재를 걱정
- RETURN_FEAR: 엇갈린 두 바늘이나 귀환 상황이 무서운지 질문
- SUPPORT_SELF_BLAME: 사용자가 실패·자책·자기비난을 말함
- SUPPORT_LISTEN: 조언 없이 들어달라고 요청
- SUPPORT_COMPANY: 해결보다 옆에 있어달라고 요청
- SUPPORT_REST: 지쳤고 쉬고 싶거나 약속을 미뤄야 함
- PLAYFUL_SMILE: 의미심장한 웃음·표정·꿍꿍이 또는 웃음 때문에 생긴 일을 장난침
- PLAYFUL_CLAIM: 비밀 요원·간식 발견처럼 확인되지 않은 일을 장난으로 단정
- PLAYFUL_COMPASS: 나침반이 정답이나 숨은 정보를 줬다고 장난침
- GENERAL: 해당 없음

경계 규칙:

1. `너 완전 X네`, `X대로 하자`, `X인 거 알지?`에서 X가 지구식 표현이면 놀림처럼 보여도 EARTH_TERM이다. `길치`, `국룰`, `TMI`는 EARTH_TERM이다.
2. `썸`, `찐친`처럼 둘의 관계를 이름 붙이면 EARTH_RELATION이다.
3. 웃음이나 표정 때문에 숨김·청소 등을 놀리면 PLAYFUL_SMILE이다.
4. 귀환 단서를 못 찾은 현재 걱정은 RETURN_FUTURE이고, 두 바늘이 무서운지는 RETURN_FEAR이다.
5. `구조 신호`라는 말만으로 RETURN 계열이 아니다. 사용자가 `빛을 따라갈까, 구조 신호를 기다릴까`처럼 두 행동을 고르면 AMBIG_CHOICE다. 쌍둥이·귀환·돌아갈 길이 중심일 때만 RETURN 계열이다.

반드시 라벨 하나만 출력한다.
