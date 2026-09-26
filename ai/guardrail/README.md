# PetAI Guardrail Baseline

status:: baseline-and-candidate-comparison-complete

이 폴더는 현재 PetAI 대화 모델의 프롬프트 인젝션, 유해 답변과 과잉 거부를
반복 측정하는 베이스라인 하네스다. 가드레일 개선, 프롬프트 튜닝, 모델
미세조정과 새 평가 문항 제작은 이 하네스의 범위가 아니다.

평가 대상은 `ai/models/runtime-models.json`에 고정된 Gemma 4 E2B IT
`.litertlm`이며 Mac에서는 LiteRT-LM OpenAI 호환 서버를 통해 생성한다.
Qwen3Guard와 Garak은 평가 대상 모델이 아니라 자동 채점기와 공격 도구다.
`prismdata/guardrail-ko-11class`는 제품 통합본이 아니라 고정된 연구 비교
후보다.

## 명령

```bash
uv sync --project ai/guardrail --extra judge --group dev

uv run --project ai/guardrail guardrail doctor
uv run --project ai/guardrail guardrail fetch
uv run --project ai/guardrail guardrail smoke
uv run --project ai/guardrail guardrail baseline
uv run --project ai/guardrail guardrail compare --profile smoke
uv run --project ai/guardrail guardrail compare --profile baseline
uv run --project ai/guardrail guardrail report --latest

uv run --project ai/guardrail pytest -q ai/guardrail/tests
swift test --package-path ai/guardrail/swift/ProductPromptAdapter
```

모든 내려받은 데이터, 모델 가중치, 원시 응답과 실행 결과는
`ai/guardrail/.artifacts/`에 저장되며 Git에서 제외된다. 공개할 수 있는 집계
결과만 검토 후 `RESULTS.md`에 기록한다.

같은 `--run-id`로 다시 실행하면 완료된 일반 응답과 자동 채점 결과를 이어서
사용한다. 전체 프로필은 공개 데이터 전체와 여러 seed를 실행하므로 장시간
작업으로 취급한다.

`compare`는 같은 profile의 가장 최근 완료된 Gemma 단독 실행을 기준점으로
선택한다. 일반 응답은 모든 입력을 가드에 통과시킨 뒤 `SAFE`만 Gemma에 보내고,
나머지는 고정 안전 안내문으로 끝낸다. Garak은 기준선의 동일 공격·동일 Gemma
출력을 짝지어 재사용하여, 통과한 공격은 기존 출력을 유지하고 차단된 공격만
고정 안내문으로 바꾼다. 따라서 생성 변동이 아니라 입력 가드 하나의 효과를
측정한다.

### 비교 조건

비교 실행은 기준선의 `evaluation_conditions`와 현재 공통 평가 조건이
일치할 때만 시작한다. 표본 제한, 데이터 출처·내용 해시, 모델 내용 해시와
실행 설정, 실제 런타임 버전, 전체 프롬프트 스냅샷, 채점기 버전·설정,
Garak 설정을 비교한다. 데이터 선택·생성·응답 정규화·채점 구현과 의존성
잠금 파일의 해시도 기록해 같은 설정으로 다른 처리 코드를 비교하지 않는다.

입력 가드의 유무·설정·후보 버전은 비교하려는 변수이므로 공통 조건에서
제외한다. 실행 ID, 시간, 파일 위치와 서버 주소도 공통 조건이 아니다.
같은 실행을 재개할 때는 가드와 기준선까지 포함한 기존 재개 검사를 적용한다.

공통 조건이 다르거나 기준선에 해당 증거가 없으면 추론·채점과 결과 파일
쓰기 전에 거절한다. 기존 산출물은 유지하며, 같은 평가 조건으로 새 기준선을
만들어야 한다. 데이터 준비와 모델 파일 검증은 이 검사보다 먼저 수행한다.

## 검증 경계

- Mac 전체 평가는 모델 품질과 회귀의 기준선이다.
- iPhone의 지연시간, 메모리, 발열과 배터리를 증명하지 않는다.
- 현재 Mac 서버의 LiteRT-LM 버전과 iOS 커스텀 런타임 버전 차이는 각 실행
  manifest에 기록한다.
- 실제 네이티브 도구, 권한 UI, 장기 기억 저장과 SQLite는 실행하지 않는다.
- 후보 가중치는 GPL-3.0이며 연구 산출물 폴더에만 내려받는다. 앱 배포물에는
  포함하지 않는다.

자세한 고정 계약은 [`SPEC.md`](SPEC.md)와 `contracts/`를 따른다.
