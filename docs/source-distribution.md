# AI 소스·빌드 자료

배포 후보의 AI 코드를 공개 소스와 연결할 때 이 안내를 사용합니다.
개발본과 공개본의 커밋 대응은 [publication.json](publication.json)에 기록합니다.
공개 범위는 [공개본 갱신 기준](publication.md)을 따릅니다.

## 빌드 입구

| 대상 | 안내 | 포함된 자료 |
| --- | --- | --- |
| 공통 대화 코어 | [빠른 시작](quickstart.md#핵심-코드-검사) | Swift 패키지·테스트·합성 입력 |
| iOS AI 실험 앱 | [실험 앱 실행](quickstart.md) | Xcode 프로젝트·네이티브 의존성 준비 스크립트 |
| Android AI 라이브러리 | [Android 연결](../android/README.md) | Swift 패키지·C ABI·메인 큐 연결·호스트 초기화 순서 |

모델 없이 코드를 검사하려면 저장소 루트에서 실행합니다.

```sh
uv sync --frozen
uv run --frozen python scripts/check.py --swift
```

LiteRT-LM 포크와 임베딩 라이브러리의 소스 버전은 준비 스크립트에 고정되어 있습니다.
Android 패키지 의존성은 `android/Package.resolved`를 사용합니다.
모델 출처와 버전은 `ai/models/runtime-models.json`에서 확인할 수 있습니다.

## 배포 후보와 연결하기

1. 빌드에 사용한 개발 커밋을 확인하고, 공개본의 AI 코드와 대조합니다.
2. `source-<앱버전>-<플랫폼>-<빌드번호>` 태그 이름을 정하고, `publication.json`의 `distribution.app_releases`에 아래 항목을 기록합니다.
3. 해당 기록을 커밋한 공개 소스에 태그를 만들고 GitHub Release를 게시합니다.
4. 앱 고지와 스토어 등록 정보의 소스 주소를 해당 태그의 GitHub Release로 연결합니다.

| 항목 | 기록할 값 |
| --- | --- |
| `platform` | `ios` 또는 `android` |
| `app_version` | 앱 버전 |
| `build_number` | 해당 플랫폼의 빌드 번호 |
| `development_commit` | 앱 빌드에 사용한 개발 커밋 |
| `public_source_tag` | 공개 소스 태그 |

GitHub Release에는 태그의 소스 아카이브와 이 빌드 안내를 연결합니다.
LiteRT-LM 포크는 준비 스크립트에 기록된 고정 커밋으로 연결합니다.
업데이트를 배포할 때는 새 태그를 만들고 기존 태그를 보존합니다.
