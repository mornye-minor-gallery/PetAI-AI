# Runtime model assets

PetAI uses two runtime model packs:

- `petai-language-model`
  - Gemma 4 E2B IT in LiteRT-LM format
- `petai-memory-model`
  - EmbeddingGemma 300M sequence-length-256 TFLite model
  - its matching `sentencepiece.model`

## Source of truth

[`runtime-models.json`](runtime-models.json) pins the Hugging Face repository,
revision, file name, byte length, SHA-256, license, and Apple asset-pack ID for
every artifact. Do not copy those values into another document.

The downloaded files live under:

```text
ai/.artifacts/runtime-models/
├── chat/gemma-e2b-it/
│   └── gemma-4-E2B-it.litertlm
└── embedding/embeddinggemma-300m/
    ├── embeddinggemma-300M_seq256_mixed-precision.tflite
    └── sentencepiece.model
```

This directory and all model file extensions are ignored by Git. Model files
must never be committed.

## Prepare models

EmbeddingGemma requires accepting its repository terms and authenticating once:

```bash
uvx --from huggingface_hub hf auth login
```

Then run:

```bash
scripts/prepare-runtime-models.sh
```

The script skips files that already match the registry. Missing files are
downloaded from the pinned Hugging Face revision and verified before use. An
existing file with the wrong byte length or SHA-256 fails closed and is never
silently replaced.

To verify already prepared files without network access:

```bash
scripts/prepare-runtime-models.sh --verify-only
```

To validate only the registry schema and Apple asset-pack identifiers:

```bash
scripts/prepare-runtime-models.sh --validate-registry-only
```

## Package for Apple hosting

After model verification:

```bash
scripts/package-ios-background-assets.sh
```

The command produces two ignored `.aar` archives under
`ios/.artifacts/background-assets/`. Packaging does not upload anything.

## Apple-hosted CI

The `Apple background assets` workflow packages the pinned artifacts on a
macOS runner and verifies App Store Connect access on every manual run. It
uploads new asset-pack versions only when the workflow input `upload` is set
to `true`; an ordinary run never creates or updates Apple-hosted content.

Repository secrets required by this workflow:

- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- `HUGGINGFACE_TOKEN`

`HUGGINGFACE_TOKEN` must be a read token from an account that has accepted the
EmbeddingGemma repository terms. Runtime model files and the temporary Apple
API key file remain runner-local and are never committed or uploaded as a
workflow artifact.
