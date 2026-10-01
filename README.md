# 별무리

AI·SW 마에스트로 서울 제17기

2026.04 ~ 2026.11 (정식 출시 예정) / 온디바이스 AI 개발

## 프로젝트 개요

별무리는 스마트폰에서 완전히 온디바이스로 실행되는 소형 언어 모델(sLM)을 통해 캐릭터와 대화하며 개인화된 경험을 제공하는 앱입니다. 그날의 중요한 기억을 매일 일기로 저장하며, 자연어로 캘린더 정리와 알람 설정 등의 네이티브 기능을 호출하여 작업하는 Agent 기능을 지원합니다.

## 담당 범위

- Effective Paramter 2.3B의 파라미터 규모를 가진 소형 언어 모델 Gemma 4 E2B 모델을 활용하여 완전한 모바일 (Android, iOS) 온디바이스 추론을 구현했습니다.
- KVCache 등의 최적화를 위해 Google의 오픈소스 엣지디바이스 추론엔진인 LiteRT-LM을 프로젝트에 맞게 직접 수정하고 적용했습니다.
- 300M의 파라미터 규모를 가진 EmbeddingGemma를 활용한, 개인화 소형 언어 모델을 위한 장기기억 아키텍쳐 EdgeMem을 직접 설계하고 적용했으며, iOS 네이티브 앱 기능 Tool Calling을 구현했습니다.
- 게임 클라이언트 Unity와 LiteRT-LM 추론엔진 실행부를 책임지는 Swift 엔진을 Application Binary Interface로 통신하여 C#과 C++ 두 언어의 동작을 통합했습니다.

## 전체 구조

작성중

사용 기술: Unity / Swift / Gemma 4 E2B / LiteRT-LM / EmbeddingGemma / SQLite

소스 코드: https://github.com/mornye-minor-gallery/PetAI-AI

## 공개 저장소 안내

별무리 개발 저장소에서 AI 추론, 장기기억, 평가 코드를 분리해 공개했습니다.

- [`ios/EdgeLLM/`](ios/EdgeLLM/): 대화·기억·라우팅 구현과 테스트
- [`ios/EdgeLLMLab/`](ios/EdgeLLMLab/): 모델을 직접 실행하며 확인하는 실험 앱
- [`ai/`](ai/README.md): 모델 평가와 연구 코드

구조와 설계 과정은 [AI 기술 문서](https://pysunn.me/docs-beolmuri-ai/)에 정리했습니다. 실험 앱을 실행하려면 [실행 안내](docs/quickstart.md)를 참고해 주세요.

메모리·라우팅 구현과 평가 자료는 [AI 구현과 연구 링크](docs/ai-links.md)에서 찾아볼 수 있습니다.

이 저장소는 팀 프로젝트에서 분리했으며, 각 구현의 기여자는 Git 이력에서 확인할 수 있습니다. 변경을 제안할 때에는 [기여 기준](CONTRIBUTING.md)을 참고해 주세요.

자체 코드의 재사용 라이선스는 아직 지정하지 않았습니다. 외부 코드와 데이터의 이용 조건은 [출처 및 이용 조건](THIRD_PARTY_NOTICES.md)에 정리했습니다.
