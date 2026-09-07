# 이름 지시 구조 비교

두 시스템 프롬프트 구조의 이름 정정 행동을 고정된 합성 데이터셋에서 비교한다.
이 실험은 이미 일부 입력을 확인한 뒤 수행하는 반복 측정이며, 미관측 데이터에
대한 독립적인 확증 실험이나 일반적인 성공률 보장을 뜻하지 않는다.

## 실행 전에 고정한 조건

- 기준 조건 `identity-statement`: 짧은 이름 지시를 메모리 출력 규칙 앞에 둔다.
- 비교 조건 `response-action`: 이름을 따옴표로 구분하고 정정 행동을 지정하며,
  예시 두 개와 함께 메모리 출력 규칙 뒤에 둔다.
- 두 조건 모두 실제 Swift에서 조립하며 `prompts/`의 예비 실험 사본과 정확히
  일치하는지 테스트한다. 문구·위치·예시를 함께 바꾸므로 개별 효과는 분리하지 않는다.
- Gemma 4 E2B IT 모바일 혼합 정밀도 QAT, 제품 레지스트리와 동일한 SHA-256.
- Mac LiteRT-LM 0.13.1 GPU, 비추론, 온도 0.7, top-k 40, top-p 1,
  최대 출력 4096, 추측 디코딩 없음. 시드 0·1·2.
- 기본 JSONL 40행: 잘못된 호명 20행과 정상 호명 대조 20행. 조건별 120회,
  두 조건 합계 240회. 정상 호명은 질문 네 종류가 반복되며 독립적인 20종이 아니다.
- 단일 턴, GENERAL 장면, 빈 대화 이력·회수 기억. 입력마다 새 대화.
- 기존 Swift 응답 파싱과 필요시 답변 재시도를 유지하고 재시도 횟수를 기록한다.
- 채점: Codex CLI gpt-5.6-luna medium. 조건명과 시스템 프롬프트를 숨기고
  사용자 발화·표시 응답·고정 채점 기준만 전달한다.
- 주 지표: 잘못된 호명에서 명확한 자기 이름 정정 또는 호명 대상 확인의 비율.
  단순 이름 언급과 자기소개인지 호명인지 애매한 표현은 통과시키지 않는다.
- 보조 지표: 네 판정의 분포, 정상 호명 오정정률·판정 불가율, 시드별 비율,
  동일 입력·시드의 성공/실패 전환, 생성 지연과 재시도·오류 수.
- 채점 기준은 14개 고정 예제로 점검하고 두 조건에 동일하게 적용한다.
  이전 예비 실험의 느슨한 채점 비율과 직접 합산하지 않는다.
- 결과를 본 뒤 프롬프트·데이터·채점 기준을 변경하지 않는다. 오류는 별도로
  기록하고 체크포인트로 재개하며 실패 응답을 제외하거나 유리한 시드로 교체하지 않는다.
- 같은 입력의 반복은 독립적인 새 문제로 취급하지 않는다. 이 실험에서 통계적
  유의성이나 긴 대화·다른 캐릭터·실제 iPhone 성능을 주장하지 않는다.

## 재현

저장소 루트에서 모델과 LiteRT Python 환경을 지정한 후 실행한다.

```zsh
beolmuri-eval build
uv run --project ai/beolmuri-eval python ai/beolmuri-eval/experiments/name-structure/calibrate.py
beolmuri-eval validate --config ai/beolmuri-eval/experiments/name-structure/config.yaml
beolmuri-eval run --config ai/beolmuri-eval/experiments/name-structure/config.yaml --variant identity-statement
beolmuri-eval run --config ai/beolmuri-eval/experiments/name-structure/config.yaml --variant response-action
beolmuri-eval compare <기준-run-id> <비교-run-id>
```

원본 로그·실행 환경은 무시되는 `.artifacts/runs/`에 보관한다. 커밋할 증거에는
합성 입력·모델 응답·판정 근거·설정·해시를 포함하고 개인 경로와 CLI 원본 로그를 제외한다.
제품 기본 설정에서는 이름 강제 규칙이 꺼져 있으며 이번 실험으로 자동 활성화하지 않는다.


두 run이 완료되면 다음 명령으로 커밋할 증거를 내보낸다.

```zsh
uv run --project ai/beolmuri-eval python ai/beolmuri-eval/experiments/name-structure/export.py <기준-run-디렉터리> <비교-run-디렉터리> ai/beolmuri-eval/experiments/name-structure/results
```
