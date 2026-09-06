# EmbeddingGemma iOS native package

This package exposes the CPU-first EmbeddingGemma runner used by EdgeLLMLab.
It follows Google's official LiteRT semantic-similarity sample:

- LiteRT revision: `1921f3defc8413a3a6bd23ad6a4d5fe35520a2c0`
- SentencePiece revision: `31646a467d2051eb904e0b45de3a73e91fe1c1e3`
- iOS deployment target: 15.0

The generated native dependencies and model weights are intentionally not
committed. Prepare the XCFrameworks before opening or building EdgeLLMLab:

```bash
scripts/prepare-ios-embedding-dependencies.sh
```

Preparation downloads a pinned release and validates its checksum and provenance.
Use `--build-from-source` to build the pinned LiteRT and SentencePiece revisions
instead. The runtime is CPU-only. Model weights are acquired separately.

The adapter follows the Apache-2.0 Google sample. See `LICENSE` and
[third-party notices](../../../THIRD_PARTY_NOTICES.md).
