# ToolRouteBench 변경 기록

## Unreleased

- 3i4K train 43,521건을 원본 발화 유형만 보존한 미라벨 PetAI 후보 풀로
  준비하고, Embedding Top-K·완화 임계값·Regex·선택적 Gemma 예측의 합집합과
  원본 라벨별 탈락 감사 표본을 생성하는 재현 가능한 마이닝 명령을 추가했다.
- 3i4K의 기존 질문·명령 `CALL` 매핑을 제품 정답으로 재사용하지 않고,
  라우터 출력은 감사 대상을 찾는 검색 근거로만 취급하도록 계약을 분리했다.
- 대규모 Embedding 추출 체크포인트가 25건마다 전체 JSONL을 다시 쓰던
  제곱 I/O 병목을 제거하고, 완료된 레코드만 append하도록 수정했다.
- 마이닝 후보와 탈락 표본을 라우터 근거 없이 두 독립 Codex 세션에 판정시키고,
  exact·비모호 합의만 사람 감사 대기 라벨로 남기는 재개 가능한 라벨링·조정
  명령을 추가했다.
- 전수 이중 판정 5,605건에서 잠정 합의 5,270건을 얻었고, 모든 CALL 2,018건과
  결정적 NO_CALL 2,018건으로 정확히 균형화하는 승인 전 풀 생성기를 추가했다.
- 승인된 균형 풀을 정규화 중복 제거 후 클래스·Tool 조합별 80/10/10으로
  층화하고, 기존 임베딩을 재사용하는 데이터 준비기와 Tool별 재현율 평가를
  추가했다.
- PetAI authoring 165건을 포함한 64-unit MLP를 수렴시켰다. PetAI dev에서
  threshold 0.20을 선택한 결과 내부 test 95.27%, 열린 PetAI Holdout 93.23%를
  기록했으며 걸음 수·타이머 데이터 부족에 따른 도메인 차이를 확인했다.
- 3i4K를 `CALL`/`NO_CALL`로 재매핑하는 누수 방지 데이터 준비기와
  EmbeddingGemma 768차원 벡터용 64-unit MLP head 학습기를 추가했다.
- 3i4K official test 600건에서 accuracy 88.17%를 얻었지만 PetAI Holdout
  회고 평가에서 NORMAL 오활성 16/24(66.67%)를 확인해 제품 미통합을
  결정했다. 걸음 수 조회 `get_step_count` 재현율은 20/24(83.33%)였다.
- 배포 정본 Gemma 4 E2B IT를 위한 loopback-only prompt router runner와 고정
  프롬프트·설정·manifest 증거를 추가했다.
- 기존 Holdout 192건 회고 비교에서 Exact 95.31%, Macro-F1 97.46%, NORMAL
  오활성 9/24(37.50%)를 확인했다. 전체 품질은 가장 높았지만 안전 gate로는
  부족해 제품에 통합하지 않는다.
- development 360건과 봉인 Holdout 192건을 생성·검증·동결했다.
- group-aware 5-fold OOF로 `embedding-09`를 잠그고 Holdout을 한 번 실행했다.
- Embedding 후보가 분류 품질은 높였지만 NORMAL 오활성률을 개선하지 못해
  제품 미통합을 결정하고 MVP 안전성 개선을 P0로 승격했다.
- Pilot 핵심 결과·해시·미검증 범위를 `RESULTS.md`에 추가했다.
- 615-record authoring plan과 Codex CLI 생성기를 추가했다.
- 정답 라벨을 숨기는 계약·블라인드 독립 검증 단계를 추가했다.
- registry SHA 검증, CPU EmbeddingGemma 추출과 resumable checkpoint를 추가했다.
- 33개 호환 후보 Dev grid, Regex 안전 gate와 Holdout lock runner를 추가했다.
- Swift Regex Router의 SHA 고정 Python 포트와 기준선 exporter를 추가했다.

## 0.1.0 — 2026-08-08

- Embedding-only multi-label Tool Router Pilot 계약 추가
- 7개 Tool과 615개 데이터 계획 고정
- Regex baseline 안전 gate와 Holdout 1회 정책 고정
- 계약 검증·벡터 집계·채점·후보 선택 하니스 골격 추가
