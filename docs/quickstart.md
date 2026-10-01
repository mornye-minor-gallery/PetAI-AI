# 독립 AI 실험 앱 실행

EdgeLLMLab은 Unity 없이 모델 추론·임베딩·메모리를 실험하는 iOS 앱입니다. Xcode 26.5와 Swift 6.3 이상을 기준으로 검증합니다.

## 핵심 코드 검사

```sh
uv sync --frozen
uv run --frozen python scripts/check.py --swift
```

Python 평가기와 Swift 계약 검사는 모델이나 네이티브 추론 바이너리 없이 실행합니다.

## 네이티브 바이너리 준비

```sh
bash scripts/prepare-ios-native-dependencies.sh
bash scripts/prepare-ios-embedding-dependencies.sh
```

첫 명령은 공개 LiteRT-LM 포크의 고정 커밋에서 KV 체크포인트 API를 빌드합니다.
두 번째 명령은 고정 릴리스의 임베딩 의존성을 내려받습니다. 두 경로 모두 해시와
출처를 검증하며, 산출물은 `ios/.artifacts/`에 저장합니다.

네이티브 변경 범위와 저장·복원 계약은 [LiteRTLM 연결 안내](../ios/ThirdParty/LiteRTLM/README.md)에 있습니다.
임베딩 의존성도 직접 빌드하려면 다음 명령을 사용합니다.

```sh
bash scripts/prepare-ios-embedding-dependencies.sh --build-from-source
```

## 서명 없이 컴파일

```sh
xcodebuild \
  -project ios/EdgeLLMLab/EdgeLLMLab.xcodeproj \
  -scheme EdgeLLMLab \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .artifacts/lab-build \
  CODE_SIGNING_ALLOWED=NO \
  PETAI_DIALOGUE_CONTENT="$PWD/examples/dialogue-content.json" build
```

이 명령은 시뮬레이터용 컴파일을 검사합니다. 실제 모델 추론이나 iPhone 성능을 검증하는 명령은 아닙니다.

`examples/dialogue-content.json`은 공개 테스트용 가상 캐릭터입니다. 직접 만든 콘텐츠를
사용하려면 `PETAI_DIALOGUE_CONTENT`에 해당 JSON의 경로를 전달합니다.

## 기기에서 실험

1. [모델 준비 안내](../ai/models/README.md)에 따라 모델 파일을 준비합니다.
2. Xcode에서 `ios/EdgeLLMLab/EdgeLLMLab.xcodeproj`를 엽니다.
3. 개인 기기에서 실행할 때는 `Signing & Capabilities`에서 본인의 Team과 고유 Bundle Identifier를 선택합니다. 로컬 Team 설정은 `ios/EdgeLLMLab/Config/Signing.local.xcconfig.example`을 참고합니다.
4. 앱의 `Chat` 탭에서 `Choose and load .litertlm model`로 언어 모델을 선택합니다.
5. `Embedding` 탭에서 임베딩 모델과 토크나이저를 준비하고, 대화·검색 결과와 표시되는 상태를 확인합니다.

사용자 발화와 기억은 로컬 실험 입력입니다. 실제 사용자 데이터 대신 직접 작성한 예제로 시작하고, 로그나 메모리 파일을 Git에 추가하지 않습니다.

## 외부 도구 라우터 산출물

도구 라우팅 구현은 포함하지만 학습된 가중치는 제공하지 않습니다. 사용 권한을 확인한 산출물을 준비한 뒤 `NativeToolRouterArtifactRegistry(manifestSHA256:loader:)`에 고정 manifest 해시와 파일 로더를 전달합니다. 파일 누락·손상·계약 불일치는 오류로 반환합니다.

`ToolRouteBench`의 exporter는 manifest와 바이너리를 만드는 코드를 제공합니다. 자체 데이터로 실험할 때도 개발·평가 데이터의 분리와 공개 조건을 따로 확인해야 합니다.

공통 대화 컨트롤러에는 `toolRouterArtifacts`로 해당 레지스트리를 전달합니다.
생략하면 학습 기반 도구 라우팅을 활성화하지 않으며 초기화 로그에 표시합니다.

## Android 연결

공통 Swift 코어와 네이티브 라이브러리의 빌드·호스트 연결은 [Android 안내](../android/README.md)를 참고해 주세요.
