# PetAI AI

제17기 서울 AISW마에스트로 **온디바이스 개인화 메모리 기반 캐릭터 육성 게임 PetAI**의 AI 연구·런타임 공개 저장소입니다.

사용자 발화에서 기억할 내용을 고르고, 기기에 저장한 기억을 검색해 다음 대화에 반영하는 과정을 구현합니다. 메모리 품질 평가, 장면·도구 라우팅, 네이티브 도구 인자 제안 실험도 포함합니다.

[전체 게임 저장소](https://github.com/mornye-minor-gallery/PetAI)는 에셋 라이선스 사유로 비공개로 유지합니다. 이 저장소에는 Unity 프로젝트, 게임 이미지·음원·폰트, 제품 배포 설정이 포함되지 않습니다.

변경을 제안하거나 비공개 개발 저장소의 코드를 옮길 때에는 [공개 저장소 기여 기준](CONTRIBUTING.md)을 먼저 확인합니다.

## 먼저 보기

| 관심 영역 | 코드와 설명 |
| --- | --- |
| 실제 메모리 저장·검색 구현 | [EdgeLLM 메모리](ios/EdgeLLM/Sources/EdgeLLM/Memory/) |
| 메모리 품질을 어떻게 평가했는가 | [EdgeMemBench](ai/edgemembench/README.md) |
| 메모리 저장 여부 분류 | [Memory Classifier](ai/memory-classifier/README.md) |
| 장면 라우팅 | [FacetRouteBench](ai/facetroutebench/README.md) |
| 도구 실행 여부와 종류 판정 | [ToolRouteBench](ai/toolroutebench/README.md) |
| 독립 실험 앱 실행 | [EdgeLLMLab 실행 안내](docs/quickstart.md) |
| 전체 연구 목록과 해석 범위 | [AI 연구 인덱스](ai/README.md) |

## 모델 없이 검증하기

Python 3.12, [uv](https://docs.astral.sh/uv/)와 `jq`가 필요합니다. Swift 테스트는 Swift 6.3 이상을 갖춘 macOS에서 실행합니다.

```sh
git clone https://github.com/mornye-minor-gallery/PetAI-AI.git
cd PetAI-AI
uv sync --frozen
uv run --frozen python scripts/check.py

# macOS에서 Swift 패키지 테스트까지 실행
uv run --frozen python scripts/check.py --swift
```

검사는 모델 다운로드나 추론 서버 없이 실행됩니다. 진행 상태는 터미널에 표시되며, 검사별 로그와 종료 상태는 `.artifacts/checks/`에 저장됩니다. 학습·추론 실험의 의존성은 각 연구 폴더의 고정 환경과 실행 안내를 따릅니다.

## 구현과 연구 결과의 관계

- `ios/EdgeLLM/`은 메모리·프롬프트·라우팅·도구 제안의 Swift 구현과 테스트를 제공합니다.
- `ios/EdgeLLMLab/`은 모델 파일을 직접 선택해 추론·임베딩·메모리를 실험하는 앱입니다.
- `ai/`의 결과는 해당 데이터·모델·실험 조건에서 얻은 연구 기록입니다. 모든 연구 후보가 실험 앱에 연결된 것은 아닙니다.
- Mac 품질 평가, Swift 테스트, 서명 없는 시뮬레이터 빌드는 iPhone의 추론 속도·메모리·발열·배터리 검증을 대신하지 않습니다.
- 도구 라우터의 학습 가중치는 제공하지 않습니다. 호출자가 공개 권한을 확인한 산출물과 manifest 해시를 공급해야 합니다. 구현 테스트는 직접 작성한 합성 입력을 사용합니다.

## 이력과 기여

PetAI `main`의 관련 경로에서 **63개 커밋의 개발 이력**을 추출했습니다. 작성자·작성 시각과 해당 경로의 변경 내역을 보존했으며, 공개 제외 파일과 일부 문서를 정리하는 과정에서 커밋 해시는 변경되었습니다. 원본에서 Squash된 작업의 병합 전 개별 커밋과 GitHub PR·리뷰·이슈는 포함하지 않습니다.

이 저장소는 팀 프로젝트에서 분리되었습니다. 각 구현의 기여자는 Git 이력으로 확인할 수 있으며, 저장소 전체를 개인 단독 작업으로 표현하지 않습니다. 연구 보고서의 시점별 결과와 현재 코드의 상태를 함께 확인해 주세요.

## 공개 범위와 이용 조건

모델 원본, 외부 데이터 원문·번역 캐시, 출처가 불명확한 학습 가중치와 실사용 대화 기록은 배포하지 않습니다. 데이터는 각 출처의 조건에 따라 별도로 준비합니다.

이 저장소 공개는 프로젝트 자체 코드에 대한 포괄적인 오픈소스 라이선스 부여를 의미하지 않습니다. 자체 코드의 재사용 라이선스는 아직 지정하지 않았습니다. 외부 코드와 데이터에는 각각의 원래 조건이 적용됩니다. [이용 조건과 출처](THIRD_PARTY_NOTICES.md)를 확인해 주세요.
