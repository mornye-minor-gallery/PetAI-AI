status:: research-note

# FacetRouteBench 라우트별 threshold 연구 기록

date:: 2026-08-07
benchmark:: FacetRouteBench
candidate:: utterance_prototype
result_status:: retrospective_exploration
decision:: conclude_embedding_router_threshold_experiment

## 결론

모든 전문 라우트에 `0.7352116498` 하나를 적용하는 전역 threshold보다, **라우트별 threshold를 전역값 방향으로 75% 수축하고 라우트별 차이를 25%만 반영한 방식**이 v2 회고 비교에서 소폭 우수했다.

Dev 5-fold 층화 교차검증이 선택한 규칙은 다음과 같다.

- shrinkage: `0.25`
- 동시 합격 중재: `normalized_margin = (score - threshold) / (1 - threshold)`
- 아무 전문 라우트도 합격하지 않음: `GENERAL`

단, v2 Frozen은 이 연구 전에 이미 여러 번 열람됐다. 아래 Frozen 수치는 방향성 확인용 회고 결과이며, 새 v3 Frozen을 이용한 확인적 검증이 아니다.

## 최종 결정

- MVP Scene Router의 우선 구현 후보는 Gemma 생성형 Router가 아니라 EmbeddingGemma Router다.
- GENERAL은 열거형 prototype 클래스가 아니라 전문 라우트가 합격하지 못했을 때의 기본 폴백으로 둔다.
- 전역 threshold 하나는 기준선으로만 유지한다.
- 제품 후보는 5-fold Dev 교차검증으로 선택한 정규화 라우트별 threshold 방식이다.
- v2에서 얻은 숫자를 Swift 상수로 바로 병합하지 않는다. v3 Dev에서 재적합하고 새 Frozen에서 한 번 검증한 뒤 런타임 계약을 확정한다.
- 짧은 명시적 위로 요청의 데이터 커버리지 보강은 후속 데이터 작업으로 분리한다.

이로써 v2 threshold 구조 비교 실험은 종료한다.

## 비교 결과

| 전략 | 분할 | 20-route Macro-F1 | Accuracy | GENERAL Precision | GENERAL Recall | 잘못된 전문 카드 활성화율 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 전역 threshold `0.7352` | Dev | 0.7146 | 0.7313 | 0.6497 | 0.8500 | 0.1500 |
| 전역 threshold `0.7352` | Frozen v2 | 0.7202 | 0.7284 | 0.6343 | 0.8167 | 0.1833 |
| 무보정 라우트별 threshold + threshold margin | Dev | 0.7411 | 0.7457 | 0.6322 | 0.8667 | 0.1333 |
| 무보정 라우트별 threshold + threshold margin | Frozen v2 | 0.7026 | 0.7170 | 0.5994 | 0.8542 | 0.1458 |
| CV 선택 라우트별 threshold | Dev 재적합 | 0.7292 | 0.7371 | 0.6366 | 0.8542 | 0.1458 |
| CV 선택 라우트별 threshold | Frozen v2 | **0.7257** | **0.7313** | 0.6294 | 0.8208 | 0.1792 |

전역 기준선 대비 CV 선택 방식의 Frozen v2 변화는 다음과 같다.

- Macro-F1: `+0.0055`
- Accuracy: `+0.0029`
- GENERAL Recall: `+0.0042`
- 잘못된 전문 카드 활성화율: `-0.0042`
- GENERAL Precision: `-0.0049`

개선 폭은 작다. 따라서 앱 병합 확정이 아니라 **새 Frozen에서 재현할 후보 규칙**으로 해석한다.

## 자연어 카나리

앞선 GENERAL prototype 탐색에서 측정한 전문 Top-1 점수를 CV 선택 threshold에 대입하면 다음과 같다.

| 입력 | 전문 Top-1 | 점수 | v2 threshold | 판정 | 기대 |
| --- | --- | ---: | ---: | --- | --- |
| `오늘 학교에서 너무 힘들었어, 공부하느라` | AMBIG_CAUSE | 0.6758 | 0.7349 | GENERAL | GENERAL |
| `요즘 너무 슬프고 힘들어` | SUPPORT_COMPANY | 0.6424 | 0.7377 | GENERAL | GENERAL 또는 문맥 의존 |
| `힘든데 위로 좀 해줘` | SUPPORT_LISTEN | 0.6712 | 0.7421 | GENERAL | SUPPORT_LISTEN |

라우트별 threshold는 첫 번째 과활성화는 막지만, 세 번째의 명시적 위로 요청도 함께 기각한다. 따라서 현재 결과는 **임계값 구조 개선만으로 MVP 품질이 완성됐다는 증거가 아니다.** 짧고 직접적인 실제 사용자 표현이 Authoring/Dev에 부족한 데이터 커버리지 문제가 남아 있다. 이 카나리를 보고 v2 threshold를 수동으로 낮추면 Frozen 사후 튜닝이 되므로, 다음 데이터 버전의 사전 등록된 문항군으로 보강해야 한다.

## 왜 무보정 방식이 실패했는가

전문 라우트 하나당 Dev 정답은 24개뿐이다. 각 라우트의 binary F1을 같은 Dev에 끝까지 맞춘 원 threshold는 Dev Macro-F1을 `0.7146 → 0.7411~0.7478`로 크게 올렸지만 Frozen v2에서는 `0.7009~0.7035`로 하락했다. 라우트마다 표본 24개로 서로 다른 경계를 직접 적합한 결과가 해당 Dev 표현에 과적합된 것으로 해석한다.

이에 다음 두 장치를 추가했다.

1. `gold_route_id + difficulty`로 층화한 5-fold 교차검증에서 규칙을 선택한다.
2. 라우트별 원 threshold를 공통 threshold 쪽으로 수축한다.

교차검증 최고 후보는 `shrinkage=0.25 + normalized_margin`이며 OOF Macro-F1은 `0.7217`이었다. 완전한 라우트별 값인 `shrinkage=1.0`보다 보수적인 보정이 선택됐다.

## 최종 재적합 threshold

아래 값은 v2 Dev 전체에서 구한 원 threshold에 `25%` 라우트별 차이와 `75%` 전역값을 반영한 값이다.

| Route ID | threshold |
| --- | ---: |
| AMBIG_CAUSE | 0.734859 |
| AMBIG_CHOICE | 0.738952 |
| EARTH_FOOD | 0.731967 |
| EARTH_RELATION | 0.741387 |
| EARTH_TERM | 0.738968 |
| FIRST_ARRIVAL | 0.735176 |
| FIRST_HOME | 0.734951 |
| FIRST_SIGNAL | 0.730107 |
| PLAYFUL_CLAIM | 0.735542 |
| PLAYFUL_COMPASS | 0.737797 |
| PLAYFUL_SMILE | 0.749176 |
| RETURN_FEAR | 0.752443 |
| RETURN_FUTURE | 0.741527 |
| RETURN_SIGNAL | 0.744482 |
| RETURN_SMILE | 0.756312 |
| SUPPORT_COMPANY | 0.737743 |
| SUPPORT_LISTEN | 0.742110 |
| SUPPORT_REST | 0.738946 |
| SUPPORT_SELF_BLAME | 0.720564 |

이 값은 v2용 연구 결과다. v3 Dev가 만들어지면 같은 러너로 다시 적합해야 하며 숫자를 그대로 제품 상수로 복사하면 안 된다.

## 판정 규칙

입력마다 19개 전문 라우트 점수를 계산한 뒤 다음을 적용한다.

1. 각 라우트에서 `score >= route_threshold`인지 확인한다.
2. 합격 라우트가 없으면 `GENERAL`이다.
3. 하나면 해당 라우트다.
4. 둘 이상이면 `(score - threshold) / (1 - threshold)`가 가장 큰 라우트다.
5. 완전히 동률이면 계약의 Route ID 순서를 사용한다.

GENERAL은 별도 프로토타입 의미 공간을 전부 열거하는 클래스가 아니라, 전문 라우트가 충분한 근거를 얻지 못했을 때의 기본값으로 유지한다.

## 선행 탐색과의 관계

GENERAL 프로토타입 240개를 전문 프로토타입과 직접 경쟁시킨 별도 탐색은 Frozen v2에서 Macro-F1 `0.7853`을 기록했다. 그러나 자연어 GENERAL 유형은 사실상 열려 있고, 다음 카나리에서 불안정한 경계를 보였다.

- 단순 감정 공유가 `AMBIG_CAUSE` 또는 `SUPPORT_COMPANY`로 과활성화됨
- 명시적 위로 요청이 GENERAL 프로토타입 하나와 우연히 더 가까워 `GENERAL`로 기각됨

따라서 높은 집계 점수만으로 GENERAL 프로토타입 열거 방식을 채택하지 않고, 라우트별 전문 gate를 우선 연구했다.

## 재현 정보

- 데이터: v2 Dev 696개, Frozen 696개
- Dev SHA-256: `95025e6bb9e3cd881122b3ecfa91dfb3e3a453024fc73bf527b4ea6a4142280d`
- Frozen SHA-256: `b25652cd6c6250a2a6d49ca83b6beeb9024e4a74da7c71597ff62ca636ed9506`
- 임베딩 SHA-256: `c785ee6710bd0482267e02f2586ac4d12de9ec8eb660444803d1ffe805557445`
- 모델: `litert-community/embeddinggemma-300m-seq256-mixed-precision`
- 모델 revision: `870cbe05ef460385363c6b574c851ae5d8989ce3`
- 모델 SHA-256: `37115ef7bff76cd37dd86abe503ff511b1032bf85fc624a85c49c84899e92bc5`
- tokenizer SHA-256: `d6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7`
- runtime: `ai-edge-litert 2.1.3`, CPU, macOS arm64, Python 3.12.13
- 원시 결과: `.artifacts/authoring-v2/per-route-thresholds-v3/`

```bash
uv run --project ai/facetroutebench frbench compare-route-thresholds \
  --dev ai/facetroutebench/.artifacts/authoring-v2/dataset/dev.v2.jsonl \
  --frozen ai/facetroutebench/.artifacts/authoring-v2/dataset/frozen.v2.jsonl \
  --embeddings ai/facetroutebench/.artifacts/authoring-v2/embeddings-warm/embeddings.jsonl \
  --output-dir ai/facetroutebench/.artifacts/authoring-v2/per-route-thresholds-v3
```

## 다음 확인 게이트

1. v3 데이터 계약을 고정하고 새 Dev로 threshold와 전략을 다시 선택한다.
2. 선택 결과와 v3 Frozen SHA-256을 먼저 잠근다.
3. v3 Frozen은 한 번만 실행한다.
4. 전역 기준선 대비 Macro-F1, GENERAL Recall, 잘못된 전문 카드 활성화율을 함께 본다.
5. 품질이 유지되면 Swift 라우터 계약으로 옮기고, iPhone에서 지연시간·메모리·발열을 별도 측정한다.

iPhone 성능은 아직 `UNVERIFIED`다.
