# iOS 자원 측정

현재 지원하는 경로는 `inference` 대상의 `basic` 프로필이다. Unity와 상세 계측은 설계에 포함되지만 아직 실행할 수 없다. 일반 앱과 구별되는 `.resourcebench` 번들을 사용한다.

평가 하네스 디렉터리에서 실행한다.

```sh
uv run beolmuri-eval resource build --signed
uv run beolmuri-eval resource validate --config experiment.yaml
uv run beolmuri-eval resource doctor --device DEVICE_ID --json
uv run beolmuri-eval resource provision --config experiment.yaml --device DEVICE_ID
# 모델 전송·왕복 검증 후 선을 분리하고 Wi-Fi에 다시 연결한다.
uv run beolmuri-eval resource run --config experiment.yaml --device DEVICE_ID --app APP_PATH --model-preinstalled
uv run beolmuri-eval resource status RUN_DIRECTORY
uv run beolmuri-eval resource cancel RUN_DIRECTORY
uv run beolmuri-eval resource collect RUN_DIRECTORY
uv run beolmuri-eval resource summarize RUN_DIRECTORY
uv run beolmuri-eval resource compare BASELINE_RUN CANDIDATE_RUN
```

`APP_PATH`는 빌드 출력의 실제 앱 경로다. 빌드 정보는 저장소의 `ios/.artifacts/resource-benchmark/build.json`에 남는다. 서명에는 로컬 Xcode 개발 계정과 프로파일이 필요하다. 기기에서 개발자 신뢰가 필요하면 직접 확인해야 한다. `doctor`의 준비 표시는 앱 설치 여부까지만 뜻하며 전경 실행·추론·계측 성공을 보장하지 않는다.

설정 형식은 `contracts/resource-benchmark/config.schema.json`, 묶인 명세 예시는 `contracts/resource-benchmark/examples/manifest.json`을 따른다. 입력·모델 목록·생성 설정·초기 상태 파일 경로는 설정 파일 기준이다. 현재는 CPU 언어 모델 하나, 빈 초기 상태, 요청별 새 대화를 지원한다. 모델 목록에는 로컬 경로와 실제 SHA-256을 지정한다. 저장소에 모델 파일이나 개인 기기 식별자를 추가하지 않는다.

실행은 동일 길이의 유휴·작업 창을 번갈아 기록한다. 메모리는 앱의 `phys_footprint`이며 추론 전후 차이를 순수 액티베이션으로 해석하지 않는다. 전력은 Power Profiler가 내보내는 기기 전체 `%/hr`를 해당 창에서 시간 가중한다. 앱 단독 와트나 줄로 환산하지 않는다. 창 경계·누락·표식·상태 검증에 실패하면 숫자를 채우지 않고 이유를 남긴다.

최초 모델 전송은 `provision`으로 측정과 분리한다. 전송 후 기기 파일을 다시 내려받아 SHA-256을 검증하며, 반환된 파일도 전송 증거로 보존한다. `--model-preinstalled`는 재전송만 생략하고 앱의 모델 해시 검증은 유지한다. 전송 완료는 모델 로드나 추론 성공을 뜻하지 않는다.

무선 측정에서는 충전선을 분리하고 화면 잠금을 풀어 둔다. 측정 앱은 실행 중 자동 잠금을 억제하지만 전원 버튼으로 잠그거나 다른 앱으로 전환하면 실험 조건을 만족하지 못한다. 모델 전송과 해시 확인은 측정 창 밖에서 수행한다.

원본과 실패 기록은 `.artifacts/resource-runs/`에 보존한다. 자동 삭제·실험 재시도·중단 실행 이어 붙이기는 하지 않는다. 요약을 다시 실행하면 새 분석 디렉터리를 만든다. 도구의 종료 코드만으로 성공을 판정하지 않는다. 호스트가 죽었거나 실행 응답이 유실됐다면 실제 앱·수집기 종료를 확인하기 전까지 남은 소유권을 임의 삭제하면 안 된다. 완전한 자동 복구는 아직 구현 대상이다.

`resource agentctl` 뒤에는 같은 명령을 전달할 수 있다. 예약 취소는 `cancel RUN_DIRECTORY --after-ms MILLISECONDS`를 사용한다. 화면 캡처와 강제 종료 인터페이스는 아직 제공하지 않는다.

전력 수집은 `--all-processes`를 사용하고 분석 구간은 앱의 실행 ID·PID로 제한한다. 수집 범위가 다른 결과는 기본 비교를 거부한다. 각 구간 뒤에는 하네스가 소유한 측정 앱을 종료하고 다음 구간에서 다시 실행한다. 화면이 닫히는 것만으로 충돌로 판정하지 않으며 종료 명령·앱 상태·기기 오류를 대조한다.

`phys_footprint`에는 수정되지 않은 파일 매핑 페이지 등이 모두 포함되지 않으므로 전체 물리 RAM 사용량과 같지 않다. 런타임 캐시의 최초 생성 여부는 현재 자동 통제·비교 검증 대상이 아니다. 서로 다른 실행의 차이를 모델이나 문맥 길이만의 영향으로 단정하지 않는다.

Instruments가 종료 후 심벌 처리 중 정체하면 실패로 기록하고 원본과 소유권을 보존한다. 다음 실험 전에 실제 수집기 종료 확인이 필요하다. RAM 전용 진단과 TestFlight 외부 관측은 현재 정식 실행 모드가 아니다.
