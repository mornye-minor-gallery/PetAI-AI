# LiteRT-LM 연결과 KV 체크포인트

Swift 연결 코드는 Apache-2.0이며 [원문 라이선스](LICENSE)를 보존합니다. 네이티브 엔진은 [고정한 LiteRT-LM 포크](https://github.com/mornye-minor-gallery/LiteRT-LM/tree/939b09f5ac92974bb4a7df430d440c2b8780941e)와 이 폴더의 패치로 빌드합니다. 모델 파일과 빌드한 바이너리는 저장소에 포함하지 않습니다.

## 빌드 입력

iOS에서는 저장소 루트에서 `bash scripts/prepare-ios-native-dependencies.sh`를 실행합니다. 스크립트는 소스 압축 파일·패치·Bazel의 해시를 확인하고 기기 및 시뮬레이터용 XCFramework를 만듭니다. `--print-config`로 필요한 빌드 식별값을 볼 수 있습니다. 기존 프레임워크는 provenance, 두 슬라이스의 바이너리 해시와 필수 심볼이 일치할 때 재사용합니다.

| 패치 | 적용 경로와 목적 |
| --- | --- |
| `prefix-cursor.patch` | iOS·Android에서 캐시 접두부를 찾은 뒤 실행 커서를 실제 재사용 위치에 맞춥니다. 새 입력이 기존 KV를 덮어쓰는 문제를 수정합니다. |
| `cpu-prefill-chunk.patch` | CPU prefill 그래프 크기 상한을 C API로 전달합니다. iOS 런타임은 128토큰을 지정하고, 정적 실행기는 큰 그래프를 arena 할당 전에 제외합니다. |
| `xnnpack-channelwise-scale.patch` | iOS 빌드의 XNNPACK에 채널별 스케일 버퍼 수정 사항을 적용합니다. 마지막 두 텐서 차원을 제외한 배치 크기로 버퍼를 할당합니다. |
| `gpu-checkpoint.patch` | Android GPU 빌드에서 물리 KV 뱅크와 순서를 저장·복원합니다. Mac 네이티브 통합 검사도 이 패치를 사용합니다. |

XNNPACK 수정은 [공식 커밋 c72e2a4](https://github.com/google/XNNPACK/commit/c72e2a4ae0efb7c648f73835e9a0133e7bf21a23)의 backport입니다. 빌드 스크립트는 고정 XNNPACK 소스와 패치 적용 후 파일의 해시를 확인하고 Bazel의 `--override_repository`로 전달합니다. 이 패치에도 XNNPACK의 [라이선스](LICENSE-XNNPACK)가 적용됩니다.

`PETAI_LITERTLM_BUILD_JOBS`로 iOS 빌드 병렬 수를 지정할 수 있으며 기본값은 10입니다. Android는 [CPU·GPU 빌드 안내](../../../android/README.md)를 따릅니다. 엔진과 Swift 리소스의 해시가 연결되므로 두 빌드의 결과를 섞지 않습니다.

EmbeddingGemma용 LiteRT·SentencePiece 프레임워크는 별도 준비 스크립트 `scripts/prepare-ios-embedding-dependencies.sh`에서 관리합니다.

## 전체 입력의 KV 재사용

`Engine.createCachedSession`은 Gemma 4 텍스트 입력에 Session C ABI를 사용합니다. 요청마다 완성된 입력을 전달하고 `session_rewind_to_step(0)` 이후 네이티브 접두부 비교로 같은 토큰을 재사용합니다. CPU와 Android GPU는 같은 Swift 어댑터를 사용합니다.

`replaceInput`은 새 앱 요청을 시작합니다. 호스트가 최근 대화와 동적 내용을 다시 공급합니다. 그 사이의 재시도에는 앞서 보인 답변을 공식 채팅 템플릿으로 넣습니다. 샘플링이나 출력 상한이 바뀌면 네이티브 세션을 교체합니다.

템플릿 렌더링에는 prefill하지 않은 임시 Conversation을 사용합니다. 그 객체의 토큰 수를 조회하면 실행 컨텍스트 획득이 발생하므로, 렌더링 결과를 엔진 토크나이저로 측정합니다. 새 Session이 BOS를 추가하므로 전달 문자열에서는 BOS를 한 번 제거합니다.

취소 후에도 마지막 콜백이 끝날 때까지 세션을 소유합니다. 생성 중에는 rewind하지 않습니다. Gemma의 채널 구분자가 여러 청크로 나뉘어 도착해도 필터가 이를 모아 처리합니다. 출력 토큰 상한에 도달하면 생성한 답변과 `finishReason=token_limit`을 반환하고, 다른 네이티브 오류는 호출 측에 전달합니다.

`matchingInputPrefixTokens`는 두 입력의 같은 접두부 길이입니다. 실제 KV 적중량이나 속도 개선을 측정한 값은 아닙니다. 턴별 지연은 런타임의 `first_response_seconds`로 관찰합니다.

## 파일과 실패 처리

앱은 보이는 대화 턴을 저장한 뒤 KV 체크포인트를 저장합니다. 캐시 경로는 앱 캐시 디렉터리의 `LiteRTLM/<cpu|gpu>/Session/latest.kv`입니다. 임시 파일을 쓴 뒤 원자적으로 교체하며, 대화 기록·SQLite 기억·일기는 각 저장소에서 유지합니다.

캐시 식별값에는 모델 SHA-256, 문맥 용량, 백엔드, 엔진 식별자와 앱 호환 버전이 들어갑니다. 같은 파일명으로 모델을 교체해도 이전 캐시를 재사용하지 않습니다. 모델 해시는 준비 단계에서 청크 단위로 계산합니다.

`litert_lm_session_transfer_state`는 유휴 상태의 세션을 독점한 호출자가 동기적으로 실행합니다. 콜백 버퍼는 최대 64 KiB이며 콜백 밖으로 보관하지 않습니다. 마지막 `transfer(NULL, 0, user_data)`에서 읽기 측이 페이로드 해시와 EOF를 확인합니다. 파일 정책과 모델 식별은 앱에서, 텐서·커서·토큰·난수 상태 전송은 엔진에서 처리합니다.

CPU는 상태 형식 2, GPU는 형식 4를 사용합니다. 두 경로 모두 배치 크기 1이며 LoRA와 추측 디코딩을 사용하지 않습니다. 다른 백엔드나 임의 엔진 빌드 사이에서 교환할 수 있는 형식은 아닙니다.

GPU 저장은 KV 뱅크를 회전시키지 않는 별도 조회 경로를 사용합니다. 각 버퍼의 생산자 이벤트를 기다린 뒤 CPU에서 접근하도록 매핑하고, `PackedSize()`만큼 전송한 후 명시적으로 매핑을 해제합니다. 복원 시 할당 정책·뱅크·차원·stride·크기를 확인합니다.

상태 전송 오류 코드 `10`은 엔진을 다시 만들기 전까지 기존·신규 세션의 추론을 막습니다. GPU 복원이 도중에 실패하면 일부 뱅크가 이미 바뀌었을 수 있어 엔진을 무효화합니다. CPU 복원 실패는 상태를 지운 뒤 다시 prefill하며, 초기화도 실패하면 같은 재준비 오류를 반환합니다. 파일 쓰기 실패는 이전 캐시와 이미 저장한 대화를 유지합니다.

## 검증

- `bash scripts/test-litertlm-prefill.sh`: Swift/C 설정 전달 검사. 준비된 소스 경로를 인자로 주면 C++ 그래프 선택 정책도 검사합니다.
- `bash scripts/test-litertlm-cached-session.sh`: 프레임워크 준비 후 C stub으로 수명·취소·체크포인트 경계를 검사합니다. 외부 헤더를 쓰려면 `PETAI_LITERTLM_HEADERS`를 지정합니다.
- `swift test --package-path ios/EdgeLLM --filter KVCheckpointStoreTests`: 파일 교체·해시·식별값 검사입니다.
- `Tests/PrefixCursor/`: 실제 ResourceManager와 실행 커서 테스트입니다. 준비한 소스의 `petai_cursor_tests`에 복사하고 `//petai_cursor_tests:prefix_cursor_test`를 빌드합니다.

실제 모델의 Mac 통합 검사는 다음과 같습니다. 소스와 결과 경로는 새 디렉터리를 사용합니다.

```sh
PETAI_LITERTLM_BAZEL="$PETAI_BAZEL" \
  bash scripts/test-litertlm-checkpoint-integration.sh \
  "$PETAI_LITERTLM_SOURCE_DIR" "$PETAI_MODEL_PATH" \
  .artifacts/checkpoint-run cpu 8192
```

Android에서는 대상 기기와 기기 내 모델 경로를 지정합니다.

```sh
python3 scripts/test-android-kv-checkpoint.py \
  --source "$PETAI_LITERTLM_SOURCE_DIR" \
  --native "$PETAI_LITERTLM_LIBRARY_DIR" \
  --ndk "$ANDROID_NDK_HOME" --serial "$PETAI_ANDROID_SERIAL" \
  --model "$PETAI_ANDROID_MODEL_PATH" --backend gpu \
  --result android/.artifacts/gpu-checkpoint-test
```

검사는 cold prefill, 같은 세션 재사용, 저장 후 계속 생성, 새 프로세스 복원의 출력을 비교합니다. 모델·샘플링 조건을 고정하고 시나리오 결과와 시간을 JSON에 남깁니다. GPU 검사는 OpenCL을 지원하는 기기가 필요합니다. stub 검사와 컴파일 결과만으로 기기 지연·메모리 사용량·모델 출력의 일치를 판단하지 않습니다.
