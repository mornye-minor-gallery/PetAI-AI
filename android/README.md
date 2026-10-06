# Android Swift 연결

Android에서도 `ios/EdgeLLM`의 대화·기억·프롬프트 코드를 사용합니다.
`ios/Package.swift`는 LiteRT-LM 실행부와 임베딩을 묶고, 이 폴더는 Android 호스트와의
C ABI 및 메인 큐 연결을 제공합니다. Unity 화면과 APK 패키징은 전체 게임 저장소에서 관리합니다.

## 빌드

Swift 6.4와 공식 Android SDK `swift-6.4.0-RELEASE_android`, Android NDK가 필요합니다.
`swift` 명령이 해당 도구를 가리키는지 확인합니다. Swift 런타임을 포장하는 호스트는
NDK r30의 `libc++_shared.so`를 사용합니다.

LiteRT-LM은 [고정 소스 안내](../ios/ThirdParty/LiteRTLM/README.md)의 커밋을 사용합니다.
`PETAI_LITERTLM_SOURCE_DIR`에 소스 경로, `PETAI_BAZEL`에 Bazel 7.6.1 실행 파일,
`ANDROID_HOME`과 `ANDROID_NDK_HOME`에 네이티브 빌드용 SDK·NDK 경로를 지정합니다.
엔진의 Android 빌드는 NDK r28b를 사용합니다.

```sh
cd "$PETAI_LITERTLM_SOURCE_DIR"
"$PETAI_BAZEL" build --config=android_arm64 \
  --define=LITERT_LM_FST_CONSTRAINTS_DISABLED=1 \
  --linkopt=-Wl,-z,max-page-size=16384 \
  --linkopt=-Wl,-z,common-page-size=16384 \
  --jobs=8 --progress_report_interval=15 //c:litert-lm
```

`PETAI_LITERTLM_LIBRARY_DIR`에 생성된 `liblitert-lm.so`의 디렉터리를 지정합니다.
Swift 연결 빌드에서는 `ANDROID_NDK_HOME`을 NDK r30 경로로 바꾸고,
이 저장소 루트에서 실행합니다.

```sh
sh android/poc/swift-android/prepare-core-sqlite.sh
PETAI_ANDROID_CORE_POC=1 swift build --package-path android \
  --swift-sdk swift-6.4.0-RELEASE_android \
  --triple aarch64-unknown-linux-android28 \
  -c release -j 6 --static-swift-stdlib
```

SQLite 준비 스크립트는 공식 소스 배포 파일의 SHA3-256을 확인합니다.
빌드 결과와 외부 의존성은 Git에서 제외합니다.

## 호스트 연결 순서

1. Android UI 스레드에서 Swift 라이브러리를 처음 로드합니다.
2. 같은 스레드에서 `petai_android_main_queue_install`을 호출합니다. 반환값 `1`과
   준비 콜백의 메인 스레드 확인값 `1`을 모두 확인합니다.
3. `petai_android_configure`에 `assetsDirectory`, `modelsDirectory`,
   `supportDirectory`, `cacheDirectory`를 JSON으로 전달합니다. 캐릭터 콘텐츠와
   추출한 `EdgeLLM_EdgeLLM.bundle`은 자산 경로에 준비합니다.
4. `petai_set_event_callback`으로 이벤트 수신부를 등록한 뒤 `petai_initialize`를
   호출하고 `ready` 이벤트를 기다립니다. 요청과 이벤트 형식은
   [ChatBridgeContract.swift](../ios/EdgeLLM/Sources/EdgeLLM/Chat/ChatBridgeContract.swift)에 있습니다.
5. `completion_pending` 또는 `cancellation_pending` 이벤트를 받으면 화면에 반영한 결과를
   `petai_finalize_turn`으로 전달합니다. JSON에는 같은 `requestId`, `cancelled`, `text`를 넣습니다.
   정상 완료는 이벤트의 답변 전체를, 취소는 실제 표시한 부분 답변을 전달합니다.
   이 확인을 받은 뒤 런타임이 턴 저장을 확정하고 `completed` 또는 `cancelled`를 보냅니다.

저장 경로와 기기 기능은 `AndroidChatPlatform`이 공급합니다. 걸음·알람·일정 등의
OS 도구는 현재 지원 목록이 비어 있으며 준비 중 안내를 반환합니다.
메인 큐 연결은 Android Looper의 이벤트 처리와 libdispatch의 내부 함수를 사용하므로,
Swift SDK를 갱신할 때 준비 콜백과 스트리밍·취소 후 재요청을 다시 확인해야 합니다.
