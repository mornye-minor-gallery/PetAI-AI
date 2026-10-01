# 공개본 갱신 기준

AI 런타임·연구·테스트를 선별해 개발 저장소에서 옮깁니다. 공개본에만 있는 콘텐츠
공급 방식과 이용 조건 안내는 유지합니다. 마지막 반영 기준점과 원본 커밋 대응은
[publication.json](publication.json)에 기록합니다.

## 포함 범위

- `ios/EdgeLLM`: 공통 대화 제어, 프롬프트 구성, 최근 20턴, 장기기억, 일기와 테스트
- `ios/EdgeLLMLab`, `ios/ThirdParty`, `ios/Package.swift`: 추론·임베딩·KV 연결과 독립 실험 앱
- `android/Runtime`, `android/Dispatch`: Android 호스트와 Swift 메인 큐 연결
- `ai/`, `ios/ResourceBench`, `contracts/resource-benchmark`: 평가기·계측기·합성 입력과 연구 기록

Unity 게임 프로젝트, 배포·서명 설정, 제품 캐릭터 콘텐츠, 반응풀 원문과 벡터,
학습 가중치, 제품 필터 목록, 실제 사용자 기록은 옮기지 않습니다.
외부 코퍼스 제작 폴더에 의존하는 BST 전용 실행기도 제외합니다.

## 공개본의 연결 방식

캐릭터 콘텐츠는 호출 측에서 JSON으로 전달합니다. 실험 앱을 처음 빌드할 때는
`examples/dialogue-content.json`을 사용할 수 있습니다. 학습 기반 도구 라우터는
권한을 확인한 산출물의 해시와 로더를 명시적으로 주입합니다.

FacetRouteBench와 ToolRouteBench의 과거 기준선은 각 연구 폴더의 `fixtures/`에
고정합니다. 최신 런타임으로 바꿔도 과거 평가의 입력과 정규식이 달라지지 않습니다.
Guardrail의 새 실행은 외부 캐릭터 콘텐츠와 현재 출력 예산을 읽으며,
기존 기준선과 평가 조건이 다르면 비교를 거절합니다.

## 갱신 절차

1. 마지막 반영 기준점과 새 개발본 사이에서 공개할 경로·커밋을 고릅니다.
2. 변경 패치만 옮기고 작성자·작성 시각·원본 커밋 번호를 남깁니다. 비공개 브랜치는 병합하지 않습니다.
3. 추가 파일과 중간 커밋까지 개인정보·데이터 권한·외부 라이선스를 확인합니다.
4. `uv run --frozen python scripts/check.py --swift`와 변경된 네이티브 연결을 검증합니다.
5. PR에서 공개 범위와 검증 결과를 확인한 뒤 병합합니다.

모델 추론과 기기 QA는 별도 검증입니다. 실행 방법은 [빠른 시작](quickstart.md)과
[Android 연결](../android/README.md)에 있습니다.
