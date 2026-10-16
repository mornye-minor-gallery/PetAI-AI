# 별무리

AI·SW 마에스트로 서울 제17기

2026.04 ~ 2026.11 (정식 출시 예정) / 온디바이스 AI 개발

## 프로젝트 개요

별무리는 스마트폰에서 Gemma 4 E2B를 실행해 캐릭터와 대화하는 앱입니다. 대화에서 기억할 내용을 기기에 저장하고, 이를 다음 대화와 일기에 사용합니다. 자연어 요청으로 알람·일정 등 기기 기능을 호출하는 도구 실행도 구현했습니다.

이 저장소에는 팀 개발본에서 선별한 AI 런타임과 평가 코드를 공개합니다. Unity 게임 클라이언트, 캐릭터 원문, 학습 가중치와 모델 파일은 포함하지 않습니다.

## 담당 범위

- Gemma 4 E2B와 LiteRT-LM을 연결해 iOS·Android의 온디바이스 추론을 구현했습니다. 공통 Swift 런타임을 두 플랫폼에서 사용합니다.
- LiteRT-LM의 KV 재사용과 파일 체크포인트를 수정했습니다. 캐시 접두부를 재사용할 때 실행 커서를 맞추고, CPU·GPU의 상태 저장 및 복원 실패를 처리했습니다.
- EmbeddingGemma와 SQLite를 사용하는 장기기억 구조 EdgeMem을 설계하고 구현했습니다. 기억 DB의 수명을 추론 모델과 분리해 모델을 내린 뒤에도 저장한 기억과 일기를 읽을 수 있게 했습니다.
- Unity 호스트와 Swift 런타임의 C ABI를 연결하고, 네이티브 도구의 요청 검증·사용자 확인·실행 결과 처리를 구현했습니다. Android의 OS 기능은 JNI를 거쳐 Java 구현에 연결합니다.

## 전체 구조

```text
호스트 앱
  └─ ChatSessionController
       ├─ 캐릭터별 대화 기록 · 프롬프트 구성 · 문맥 요약
       ├─ EdgeMem: EmbeddingGemma 검색 + SQLite 저장
       ├─ 도구 라우팅 → 요청 검증 → 사용자 확인 → OS 실행
       └─ LiteRTLMRuntime → LiteRT-LM → Gemma 4 E2B
                              └─ CPU / Android GPU · KV 체크포인트
```

대화 기록과 기억 DB를 복원의 기준으로 사용합니다. KV 파일은 모델·엔진·백엔드가 맞을 때만 재사용합니다. 문맥이 토큰 예산을 넘으면 요약과 최근 대화로 다시 구성하며, 캐릭터를 바꾸면 해당 캐릭터의 기록을 읽습니다.

| 살펴볼 구현 | 코드와 검증 |
| --- | --- |
| 문맥 예산과 요약 | [대화 구성](ios/EdgeLLM/README.md), [요약·취소·저장 테스트](ios/EdgeLLM/Tests/EdgeLLMTests/ChatSessionCompactionTests.swift) |
| 모델과 기억 DB 수명 분리 | [MemoryService](ios/EdgeLLMLab/EdgeLLMLab/Memory/MemoryService.swift), [DB 테스트](ios/EdgeLLM/Tests/EdgeLLMTests/MemoryDatabaseTests.swift) |
| KV 재사용과 네이티브 수정 | [패치와 검증 방법](ios/ThirdParty/LiteRTLM/README.md), [커서 회귀 테스트](ios/ThirdParty/LiteRTLM/Tests/PrefixCursor/native_test.cc) |
| 플랫폼별 도구 실행 | [공통 요청 검증](ios/EdgeLLM/Sources/EdgeLLM/ToolUse/NativeToolProposalCoordinator.swift), [Android 연결](android/README.md) |
| 평가와 연구 | [AI 구현과 연구 링크](docs/ai-links.md), [평가 코드](ai/README.md) |

사용 기술: Unity / Swift / Gemma 4 E2B / LiteRT-LM / EmbeddingGemma / SQLite / JNI / Java

## 실행과 공개 범위

[빠른 시작](docs/quickstart.md)에서 모델 없이 실행하는 검사와 iOS 실험 앱 빌드를 안내합니다. Android 호스트 연결과 CPU·GPU 빌드는 [Android 안내](android/README.md)에 있습니다. 모델 추론 품질과 실제 기기의 동작은 별도 검증이 필요합니다.

캐릭터 콘텐츠는 외부 JSON으로 공급합니다. [샘플 콘텐츠](examples/dialogue-content.json)로 실행할 수 있으며, 학습 기반 도구 라우터와 반응 검색을 사용하려면 해당 기능의 외부 산출물도 준비해야 합니다.

반영 기준점과 선별 범위는 [공개본 갱신 기준](docs/publication.md)에 기록합니다. 설계 과정은 [AI 기술 문서](https://pysunn.me/docs-beolmuri-ai/)에도 정리했습니다. 각 구현의 기여자는 Git 이력에서 확인할 수 있습니다.

변경 제안은 [기여 기준](CONTRIBUTING.md)을 따릅니다. 자체 코드의 재사용 라이선스는 아직 지정하지 않았습니다. 외부 코드와 데이터의 조건은 [출처 및 이용 조건](THIRD_PARTY_NOTICES.md)에 정리했습니다.
