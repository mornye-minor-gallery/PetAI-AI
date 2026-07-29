# Memory classifier experiments

This directory contains macOS-only reference experiments for PetAI memory
classification. It prepares the fixed dataset, extracts EmbeddingGemma
features, trains the small two-label MLP baseline, and evaluates the hybrid
Gemma header/retry/MLP policy before that policy is ported to Swift.

The extractor matches the EdgeLLM classification embedding contract:

- `litert-community/embeddinggemma-300m`
- mixed-precision sequence-length-256 TFLite artifact
- SentencePiece tokenization
- `task: classification | query: ` prefix
- truncation followed by BOS, EOS, and PAD
- raw 768-value float32 output from LiteRT `CompiledModel` on CPU

Model weights and tokenizer files stay outside Git. Every run writes their
SHA-256 values, the LiteRT version, input hashes, and output hashes to
`embedding_manifest.json`.

## Test

```bash
cd ai/memory-classifier
uv run python -m unittest discover -s tests
```

## Extract the fixed 450-record dataset

```bash
uv run python embed_dataset.py \
  --model /path/to/embeddinggemma-300M_seq256_mixed-precision.tflite \
  --tokenizer /path/to/sentencepiece.model \
  --input train=/path/to/train.jsonl \
  --input validation=/path/to/validation.jsonl \
  --input test=/path/to/test.jsonl \
  --output-dir /path/to/new-output-directory
```

The command refuses to overwrite an existing output directory. The three
output JSONL files preserve the source fields and add only `split` and the
`embedding` vector.

For the expanded 2,100-record dataset, validate and split the DataDesigner
export first:

```bash
uv run python prepare_dataset.py \
  --input /path/to/memory-classifier-2100.jsonl \
  --output-dir /path/to/splits
```

Then include the held-out synthetic challenge split and its explicit count:

```bash
uv run python embed_dataset.py \
  --model /path/to/embeddinggemma-300M_seq256_mixed-precision.tflite \
  --tokenizer /path/to/sentencepiece.model \
  --input train=/path/to/splits/train.jsonl \
  --input validation=/path/to/splits/validation.jsonl \
  --input test=/path/to/splits/test.jsonl \
  --input synthetic_challenge=/path/to/splits/synthetic_challenge.jsonl \
  --expected-count train=1600 \
  --expected-count validation=200 \
  --expected-count test=200 \
  --expected-count synthetic_challenge=100 \
  --output-dir /path/to/new-output-directory
```

## Train the baseline classifier

The first classifier is intentionally small: a 768-value embedding enters one
64-unit ReLU hidden layer and produces independent `preference` and `event`
probabilities. Training uses only the train split. The validation split selects
one threshold per label, and the test split is evaluated after those thresholds
are fixed.

```bash
uv run python train_classifier.py \
  --train /path/to/train.embeddings.jsonl \
  --validation /path/to/validation.embeddings.jsonl \
  --test /path/to/test.embeddings.jsonl \
  --challenge /path/to/synthetic_challenge.embeddings.jsonl \
  --embedding-manifest /path/to/embedding_manifest.json \
  --output-dir /path/to/new-training-output-directory \
  --seed 42
```

The output directory contains:

- `model_weights.npz`: two dense layers, biases, and thresholds
- `training_manifest.json`: configuration, provenance, hashes, and metrics
- validation and test prediction JSONL files for error inspection

This training artifact is a research baseline. It is not yet converted to or
loaded by the iOS runtime.

## Evaluate the hybrid memory policy

The reference harness mirrors the intended Swift control flow:

1. Gemma emits a memory header plus a visible chat reply.
2. `MemoryHeaderGate` hides the control header while preserving streaming
   chunks.
3. `MemoryDecisionParser` normalizes `save(P)`, `P`, and `P / reply`.
4. A label-only response gets one answer-only Gemma retry.
5. A missing or malformed label falls back to EmbeddingGemma plus the trained
   MLP.
6. A successful turn produces at most one idempotent memory commit.

Start the local LiteRT-LM OpenAI-compatible server separately, then run the
frozen test and challenge splits:

```bash
uv run python evaluate_hybrid_memory.py \
  --dataset-dir /path/to/splits \
  --embeddings-dir /path/to/embeddings \
  --weights /path/to/model_weights.npz \
  --prompt prompts/memory_tagged_chat_v10.txt \
  --model-artifact /path/to/model.litertlm \
  --runtime-version 0.13.1 \
  --splits test synthetic_challenge \
  --repeats 3 \
  --output-dir /path/to/new-hybrid-eval-output
```

For prompt tuning, keep the test splits untouched and select a small balanced
validation subset:

```bash
uv run python evaluate_hybrid_memory.py \
  ... \
  --splits validation \
  --balanced-limit-per-split 32 \
  --selection-seed 42 \
  --repeats 1
```

The output directory is never overwritten. It contains:

- `results.jsonl`: every raw generation, resolved decision, retry/fallback
  path, latency, and expected label;
- `evaluation_manifest.json`: model, prompt, dataset, embedding, and classifier
  hashes plus aggregate metrics;
- `run_state.json`: running or completed state for interrupted-run diagnosis.

Use only the validation split while changing the prompt or parser. Freeze those
inputs before evaluating the test and synthetic challenge splits.
