# 모델 준비

`runtime-models.json`은 언어 모델·임베딩 모델·토크나이저의 저장소, revision, 파일 크기와 SHA-256을 고정합니다. 모델 파일 자체는 배포하지 않습니다.

```sh
# 다운로드 없이 명세 검사
bash scripts/prepare-runtime-models.sh --validate-registry-only

# 출처의 이용 조건을 확인한 뒤 다운로드·해시 검증
bash scripts/prepare-runtime-models.sh

# 이미 받은 파일만 검증
bash scripts/prepare-runtime-models.sh --verify-only
```

`jq`와 Hugging Face CLI 또는 `uvx`가 필요합니다. 인증이 필요한 모델은 해당 출처의 접근 조건에 동의하고 `hf auth login`으로 인증해야 합니다. 토큰은 저장소에 기록하지 않습니다.

다운로드 위치는 `ai/.artifacts/runtime-models/`이며 Git에서 제외됩니다. 파일이 존재하지만 크기나 해시가 다르면 실패로 보고합니다. 캐시를 조용히 다른 모델로 대체하지 않습니다.

- 언어 모델: [Gemma E2B LiteRT-LM 배포](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)
- 임베딩과 토크나이저: [EmbeddingGemma 배포](https://huggingface.co/litert-community/embeddinggemma-300m)

각 모델의 실제 이용 조건은 출처의 모델 카드와 라이선스를 확인합니다. 이 명세의 라이선스 필드는 출처를 안내하며 별도 이용 권한을 부여하지 않습니다.
