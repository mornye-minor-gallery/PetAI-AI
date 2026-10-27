# Android Swift 연결

Android 호스트는 `ios/EdgeLLM`의 대화·기억·프롬프트 코드와 `ios/Package.swift`의 추론 실행부를 사용합니다. `Runtime/`은 C ABI, `Dispatch/`는 메인 큐, `PlatformSwift/`·`PlatformJNI/`·`Platform/`은 OS 도구 연결입니다. Unity 프로젝트와 APK 패키징은 이 저장소에 포함하지 않습니다.

## CPU·GPU 빌드

Swift 6.4와 Android SDK `swift-6.4.0-RELEASE_android`를 사용합니다. 네이티브 엔진은 Bazel 7.6.1과 NDK r28b, Swift 연결은 NDK r30으로 빌드합니다. 빌드별 SDK·NDK 경로를 `ANDROID_HOME`, `ANDROID_NDK_HOME`에 지정합니다.

저장소 루트에서 실행합니다. `--source`에는 아직 존재하지 않는 작업 디렉터리를 지정합니다. 스크립트가 고정 소스를 내려받고 패치를 적용합니다. 백엔드나 패치가 달라지면 새 디렉터리를 사용합니다.

```sh
# ANDROID_NDK_HOME: NDK r28b
python3 scripts/build-android-litertlm.py \
  --backend cpu \
  --source android/.artifacts/source-cpu \
  --bazel "$PETAI_BAZEL" \
  --output-base android/.artifacts/bazel-cpu \
  --output android/.artifacts/native-cpu

# ANDROID_NDK_HOME: NDK r30, swift: Swift 6.4
python3 scripts/build-android-swift.py \
  --backend cpu \
  --source android/.artifacts/source-cpu \
  --native android/.artifacts/native-cpu \
  --scratch android/.artifacts/swift-cpu
```

GPU를 빌드할 때는 두 명령의 `--backend`를 `gpu`로 바꾸고 각 작업 경로도 분리합니다. GPU 결과에는 `libLiteRt.so`와 고정된 OpenCL 라이브러리가 추가됩니다. Swift 빌드는 `android/dependencies/prepare-sqlite.sh`로 SQLite를 준비하며 공식 소스의 SHA3-256을 확인합니다.

결과 디렉터리의 엔진·Swift 라이브러리, `EdgeLLM_EdgeLLM.bundle`, 두 `provenance.json`을 함께 보관합니다. 다음 명령은 바이너리·리소스 해시와 백엔드 조합을 확인합니다.

```sh
python3 scripts/litertlm_prefix_cursor.py \
  --verify-android-product android/.artifacts/native-cpu --backend cpu
```

## 호스트 연결

1. Android UI 스레드에서 Swift 라이브러리를 로드한 뒤 `petai_android_main_queue_install`을 호출합니다. 반환값과 준비 콜백의 메인 스레드 확인값이 모두 `1`이어야 합니다.
2. `petai_android_configure`에 `assetsDirectory`, `modelsDirectory`, `supportDirectory`, `cacheDirectory`, `inferenceBackend`를 JSON으로 전달합니다. 백엔드는 `cpu` 또는 `gpu`입니다.
3. 자산 경로에 `dialogue-content.json`, 추출한 `EdgeLLM_EdgeLLM.bundle`, 엔진의 `liblitert-lm.provenance.json`을 복사한 `native-engine.json`을 준비합니다. 시작 캐릭터는 콘텐츠의 `id`를 사용합니다. 다른 캐릭터는 `dialogue-content.<id>.json`으로 공급하고 `petai_activate_character`로 선택합니다.
4. `petai_set_event_callback`을 등록한 뒤 요청 ID를 전달해 `petai_initialize`를 호출합니다. `ready` 이벤트를 받은 뒤 대화를 전송합니다. 모델 파일은 [모델 레지스트리](../ai/models/runtime-models.json)의 설치 규격에 맞춰 별도로 준비합니다.
5. `completion_pending` 또는 `cancellation_pending`을 받으면 화면에 반영한 답변을 `petai_finalize_turn`으로 전달합니다. JSON의 `requestId`는 같은 요청이어야 하며, `cancelled`와 `text`를 포함합니다. 저장이 확정되면 `completed` 또는 `cancelled` 이벤트가 옵니다.

요청·이벤트 형식은 [ChatBridgeContract](../ios/EdgeLLM/Sources/EdgeLLM/Chat/ChatBridgeContract.swift)에 있습니다. 학습 기반 도구 라우터는 기본으로 비활성화되어 있습니다. 사용할 호스트는 승인된 파일의 해시와 로더로 `NativeToolRouterArtifactRegistry`를 만들고 `ChatRuntimeAssembly.makeController`의 `toolRouterArtifacts`에 전달해야 합니다.

## OS 도구와 검사

알람·타이머, 캘린더, 예약 알림, 걸음 조회의 플랫폼 구현을 포함합니다. 호스트는 `PetAIPlatformBridge.install(activity)`을 호출하고 필요한 Activity·Service·Receiver와 권한을 선언해야 합니다. [검사용 앱의 manifest](tests/OwnedAlarms/device/AndroidManifest.xml)는 연결 예시입니다. 외부에서 호출 가능한 검사 전용 Activity·Receiver는 제품 앱에 포함하지 않습니다. 축소 빌드에는 [consumer-rules.pro](Platform/consumer-rules.pro)를 적용합니다.

플랫폼 Java 코드는 JDK 17과 `com.google.android.gms:play-services-fitness:21.2.0`을 사용합니다. 의존성 선언은 [검사용 앱의 Gradle 설정](tests/OwnedAlarms/device/build.gradle)에 있습니다. 이 설정은 검사 전용 호스트를 빌드하며 제품 APK의 설정을 대신하지 않습니다.

`uv run --frozen python scripts/check.py --swift`는 JVM에서 OS 도구의 순수 로직을 검사하고 Swift의 백엔드 선택·시간대 처리를 확인합니다. JDK가 필요합니다. 권한 화면, Android Looper, 센서와 OpenCL 실행은 이 검사에 포함되지 않습니다.

기기에서는 `scripts/tests/test_android_main_queue.sh`, `scripts/test-android-calendar-json.sh`와 `scripts/test-android-kv-checkpoint.py`를 사용할 수 있습니다. 대상 기기를 명시해야 하며, GPU 검사는 OpenCL을 지원하는 기기가 필요합니다. 체크포인트 검사의 입력과 판정은 [네이티브 안내](../ios/ThirdParty/LiteRTLM/README.md)를 참고합니다.
