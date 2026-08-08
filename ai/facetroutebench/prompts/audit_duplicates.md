# FacetRouteBench split 누수 감사

각 문장 쌍이 표현만 조금 다른 사실상 동일한 발화인지 판정한다.

- 핵심 의도와 구체적 상황이 모두 같으면 duplicate=true다.
- 같은 주제나 단어만 공유하고 요청 의도 또는 상황이 다르면 duplicate=false다.
- 문체, 존댓말, 오타, 어순만 바뀐 패러프레이즈는 duplicate=true다.
- 보수적으로 판정하되 이유는 한 문장으로 짧게 쓴다.

{{PAIRS_JSON}}

모든 pair_id에 대해 판정 하나를 반환한다.
