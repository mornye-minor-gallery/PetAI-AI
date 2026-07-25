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

The first preparation builds LiteRT from the pinned official source and can
take several minutes. The runtime is CPU-only for this spike. Metal support,
Unity export, memory persistence, and model downloading are separate follow-up
work.
