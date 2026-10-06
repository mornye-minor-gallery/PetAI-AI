# 도구·정규식 기준선

`KoreanNativeToolRouter.swift`는 최초 공개본에서 사용한 정규식 기준선입니다.
Python 이식본은 `contracts/tools.v1.json`에 고정한 이 파일의 해시를 검증합니다.
최신 앱 라우터의 변경이 과거 비교 실험의 조건을 바꾸지 않도록 분리했습니다.

`NativeToolKind.swift`는 공개 커밋 `6f2cda4f96f97f023e0155e057b7f4d9b5d3e02f`의
`ios/EdgeLLM/Sources/EdgeLLM/ToolUse/NativeToolContracts.swift`에서 도구 정의를 보존한 파일입니다.
이 벤치마크는 당시 7개 도구를 대상으로 하며, 현재 런타임의 새 도구는 별도 실험에서 평가합니다.
