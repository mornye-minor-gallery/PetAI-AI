# PetAI AI 연구 인덱스

온디바이스 대화·메모리·라우팅 연구를 재현하기 위한 코드와 실험 기록입니다. 연구 결과의 조건은 각 폴더의 manifest, 설정, 결과 문서에 기록합니다.

| 연구 | 다루는 문제 | 결과 해석 |
| --- | --- | --- |
| [Memory Classifier](memory-classifier/README.md) | 선호·사건의 저장 여부, 분류 기준선과 프롬프트 | 과거 MLP 기준선과 현재 Swift 저장 정책을 구분합니다. |
| [EdgeMemBench](edgemembench/README.md) | 저장·검색·시간 충돌·기권의 494문항 평가 | 저장 판단과 검색 이후 평가를 분리합니다. 시험셋에서 운영 임계값을 고르지 않습니다. |
| [Profile Memory KV](profile-memory-kv/README.md) | 구조화 프로필 추출 | 24문항 개발 실험이며 일반화 성능을 입증하지 않습니다. |
| [MRBench Custom](mrbench-custom/README.md) | 자체 창작 페르소나의 지식 경계와 응답 | Mac 실험 결과이며 iPhone 성능과 구분합니다. |
| [FacetRouteBench](facetroutebench/README.md) | 장면 라우팅과 라우트별 임계값 | 회고 실험과 새로운 평가 데이터의 결과를 구분합니다. |
| [ToolRouteBench](toolroutebench/README.md) | 도구 실행 여부와 종류 판정 | 오활성률을 별도로 평가합니다. 연구용 학습 가중치는 제공하지 않습니다. |
| [Needle 2 Argument Canary](needle2-argument-canary/README.md) | 선택된 도구의 인자 제안 | 소규모 진단 실험이며 도구 라우팅 성능은 평가하지 않습니다. |
| [모델 준비](models/README.md) | 모델 버전·해시와 다운로드 | 모델 파일은 저장소에 포함하지 않습니다. |

Swift 구현은 [EdgeLLM](../ios/EdgeLLM/), 독립 실행 안내는 [빠른 시작](../docs/quickstart.md)에 있습니다. 모델 없이 검사하려면 저장소 루트에서 `uv run --frozen python scripts/check.py --swift`를 실행합니다.

각 연구 폴더의 기존 보고서는 실험 당시의 제품·후보 상태를 설명합니다. 공개 저장소의 현재 실행 범위는 루트 README와 테스트 결과를 기준으로 합니다. `.artifacts/`에 언급된 원시 산출물은 로컬 입력이며 공개 저장소만으로 모든 과거 점수가 즉시 재현되는 것은 아닙니다.
