# 이용 조건과 출처

PetAI 팀이 작성한 코드에는 현재 포괄적인 재사용 라이선스를 지정하지 않았습니다. 소스 열람을 위한 공개 저장소이며, 공개 여부와 별개로 재사용·재배포 권한은 확인이 필요합니다. 아래 외부 구성 요소의 라이선스는 그대로 유지합니다.

| 구성 요소 | 출처와 조건 | 저장소의 취급 |
| --- | --- | --- |
| LiteRT-LM Swift 연결 코드 | [Google LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM), Apache-2.0 | [라이선스](ios/ThirdParty/LiteRTLM/LICENSE)와 원본 저작권 공지를 보존합니다. |
| EmbeddingGemma 네이티브 어댑터의 참고 구현 | [Google LiteRT samples](https://github.com/google-ai-edge/litert-samples), Apache-2.0 | [라이선스](ios/ThirdParty/EmbeddingGemmaNative/LICENSE)를 포함합니다. |
| LongMemEval | [데이터 카드](https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned), [상위 프로젝트](https://github.com/xiaowu0162/LongMemEval), MIT | [라이선스 원문](third_party/notices/LongMemEval-LICENSE)을 포함합니다. 원본 전체 데이터는 배포하지 않으며, EdgeMemBench의 선택·정리·주석 방식은 해당 문서에 기록합니다. |
| 3i4k | [공식 데이터 저장소](https://github.com/warnikchow/3i4k), CC-BY-SA-4.0 | 원문·변형 데이터는 배포하지 않습니다. 데이터 준비 코드를 포함하며, 결과를 재배포할 때는 원출처의 조건을 따릅니다. |
| HN-OOS | [원본 저장소](https://github.com/frank7li/Generating-Hard-Negative-Out-of-Scope-Data-with-ChatGPT-for-Intent-Classification), 명시적 라이선스 미확인 | 원문·번역본·해당 데이터로 학습한 가중치를 제공하지 않습니다. 제외 계약에는 문장 대신 SHA-256을 사용합니다. 준비 코드의 존재는 데이터 사용 허가를 의미하지 않습니다. |
| Gemma·EmbeddingGemma 모델과 토크나이저 | 각 Hugging Face 모델 카드와 Google 이용 조건 | 파일을 배포하지 않습니다. `ai/models/runtime-models.json`에 출처와 고정 해시를 기록합니다. |

직접 작성한 평가 예제와 페르소나 텍스트는 AI 연구 문맥의 팀 산출물입니다. 게임 이미지·음원·폰트와 상용 Unity 플러그인은 포함하지 않습니다. 추가 데이터나 바이너리를 배포할 때도 이 저장소의 공개 상태를 권한 근거로 삼지 않습니다.
