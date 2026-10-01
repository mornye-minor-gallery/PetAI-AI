"""Compile ready authored frames into a resumable private runtime index."""
import argparse
import json
import os
import struct
import time
from pathlib import Path
from .reaction_embedding import SearchEmbedder, sha
from .storage import atomic_json, run_lock


def compile_rows(source):
    frames, rows, texts, skipped = [], [], [], []
    for line_number, line in enumerate(Path(source).read_text().splitlines(), 1):
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            skipped.append({'line': line_number, 'reason': 'invalid JSON'}); continue
        if not isinstance(item, dict):
            skipped.append({'line': line_number, 'reason': 'invalid item'}); continue
        frame = item.get('frame') or {}
        if item.get('status') != 'ready':
            skipped.append({'line': line_number, 'reason': item.get('status')}); continue
        if not isinstance(frame, dict):
            skipped.append({'line': line_number, 'reason': 'invalid frame'}); continue
        example = frame.get('example') or {}
        if not isinstance(example, dict) or not isinstance(item.get('source_id'), str) or not item['source_id'].strip():
            skipped.append({'line': line_number, 'reason': 'invalid example or source ID'}); continue
        if (not all(isinstance(frame.get(k), str) and frame[k].strip() for k in ('goal', 'shape'))
            or not all(isinstance(example.get(k), str) and example[k].strip() for k in ('user', 'assistant'))
            or not isinstance(frame.get('search'), list) or not frame['search']
            or not all(isinstance(t, str) and t.strip() for t in frame['search'])):
            skipped.append({'line': line_number, 'reason': 'invalid frame'}); continue
        frames.append({'id': item['source_id'], 'goal': frame['goal'], 'shape': frame['shape'], 'example': example})
        rows.extend([len(frames)-1] * len(frame['search']))
        texts.extend(frame['search'])
    if not frames or len({f['id'] for f in frames}) != len(frames):
        raise ValueError('empty corpus or duplicate source IDs')
    return frames, rows, texts, skipped


def add_arguments(p):
    for name in ('source', 'character', 'model', 'tokenizer', 'output'):
        p.add_argument('--' + name, required=True)


def build(a):
    output = Path(a.output); output.mkdir(parents=True, exist_ok=True)
    with run_lock(output):
        _build(a)


def _build(a):
    output = Path(a.output); output.mkdir(parents=True, exist_ok=True)
    frames, rows, texts, skipped = compile_rows(a.source)
    embedder = SearchEmbedder(a.model, a.tokenizer)
    request = {'sourceSHA256': sha(a.source), 'embeddingIdentity': embedder.identity, 'characterID': a.character}
    checkpoint = output / 'reaction-build.json'
    vectors = output / 'reaction-vectors.f32'
    old = json.loads(checkpoint.read_text()) if checkpoint.exists() else None
    if old and old['request'] != request:
        raise ValueError('checkpoint belongs to different input/model')
    if not old and vectors.exists():
        raise ValueError('vectors without checkpoint')
    completed = old['completed'] if old else 0
    def save():
        atomic_json(checkpoint, {'request': request, 'completed': completed, 'total': len(texts), 'skipped': skipped})
    save()
    started = time.monotonic(); initial = completed; last = started
    try:
        with vectors.open('r+b' if vectors.exists() else 'w+b') as stream:
            if stream.seek(0, 2) < completed * 768 * 4:
                raise ValueError('checkpoint ahead of durable vectors')
            stream.truncate(completed * 768 * 4); stream.seek(0, 2)
            for text in texts[completed:]:
                vector = embedder.embed(text, document=True)
                stream.write(struct.pack('<768f', *vector)); completed += 1
                if completed % 25 == 0 or time.monotonic() - last >= 10 or completed == len(texts):
                    stream.flush(); os.fsync(stream.fileno()); save()
                    elapsed = time.monotonic() - started
                    eta = elapsed / (completed-initial) * (len(texts)-completed)
                    print(f'[진행] 임베딩 {completed}/{len(texts)} ({completed/len(texts):.1%}) 남은 예상 {eta/60:.1f}분', flush=True)
                    last = time.monotonic()
        metadata = {'version': 1, **request, 'dimension': 768, 'frames': frames, 'rows': rows,
                    'vectorsSHA256': sha(vectors)}
        temp = output / 'reaction-frames.tmp'
        temp.write_text(json.dumps(metadata, ensure_ascii=False)); temp.replace(output / 'reaction-frames.json')
    finally:
        embedder.close()

def main():
    p = argparse.ArgumentParser()
    add_arguments(p)
    build(p.parse_args())

if __name__ == '__main__':
    main()
