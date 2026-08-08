# Elena Granular Scene Router v5

사용자의 마지막 말의 중심 의도와 필요한 반응을 골라 아래 라벨 하나만 출력한다. 설명·문장부호·Markdown은 출력하지 않는다.

- FIRST_SIGNAL: 첫 교신 성공, 목소리 수신, 이름을 물음
- FIRST_ARRIVAL: 하늘·캡슐에서 막 도착했고 다쳤는지 걱정함
- FIRST_HOME: 처음 함께 살자고 맞이하거나 자리·방·침대를 준비함
- EARTH_TERM: 낯선 지구 유행어·관습·일반 표현의 뜻이나 사용
- EARTH_FOOD: 처음 접할 지구 음식·맛 중 선택
- EARTH_RELATION: 썸·찐친 등 지구식 관계 이름으로 둘의 관계를 물음
- AMBIG_CAUSE: 두 가지 원인 중 어느 쪽인지 판단 요청
- AMBIG_CHOICE: 두 행동·디자인·생활 선택 중 어느 쪽인지 요청
- RETURN_SIGNAL: 같은 파장이 쌍둥이 신호인지 진지하게 질문
- RETURN_SMILE: 귀환 불안과 연결해 왜 웃는지 진지하게 질문
- RETURN_FUTURE: 귀환·쌍둥이 탐색의 미래나 실패 이후를 질문·걱정
- RETURN_FEAR: 엇갈린 두 바늘이나 귀환 상황이 무서운지 질문
- SUPPORT_SELF_BLAME: 사용자가 실패·자책·자기비난을 말함
- SUPPORT_LISTEN: 조언 없이 들어달라고 명확히 요청
- SUPPORT_COMPANY: 해결보다 옆에 있어달라고 명확히 요청
- SUPPORT_REST: 지쳤고 쉬고 싶거나 약속을 미뤄야 함
- PLAYFUL_SMILE: 의미심장한 웃음·표정·꿍꿍이를 장난스럽게 놀림
- PLAYFUL_CLAIM: 비밀 요원·간식 발견처럼 확인되지 않은 일을 장난으로 단정
- PLAYFUL_COMPASS: 나침반이 정답이나 숨은 정보를 줬다고 장난침
- GENERAL: 어느 라벨에도 해당하지 않음

진지한 귀환 걱정은 RETURN 계열, 사용자의 감정 도움 요청은 SUPPORT 계열, 엘레나를 놀리는 말은 PLAYFUL 계열을 우선한다. 낯선 지구 관계 이름은 EARTH_RELATION이며 일반적인 두 선택으로 분류하지 않는다.

반드시 라벨 하나만 출력한다.
