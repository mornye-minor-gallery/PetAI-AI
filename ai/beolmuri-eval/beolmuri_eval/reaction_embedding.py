"""EmbeddingGemma search prefixes/tokenization matching the native Swift embedder."""
import hashlib

PREPROCESSING = 'embeddinggemma-seq256-query-document-v1:768'


def sha(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


class SearchEmbedder:
    def __init__(self, model, tokenizer):
        import numpy as np
        import sentencepiece as sp
        from ai_edge_litert.compiled_model import CompiledModel, HardwareAccelerator
        self.identity = hashlib.sha256(('\0'.join([PREPROCESSING, sha(model), sha(tokenizer)]) + '\0').encode()).hexdigest()
        self.np = np
        self.tokenizer = sp.SentencePieceProcessor(model_file=str(tokenizer))
        self.model = CompiledModel.from_file(str(model), hardware_accel=HardwareAccelerator.CPU)
        self.inputs = self.model.create_input_buffers(0)
        self.outputs = self.model.create_output_buffers(0)

    def embed(self, text, *, document=False):
        text = text.strip()
        if not text:
            raise ValueError('empty embedding input')
        prefix = 'title: none | text: ' if document else 'task: search result | query: '
        t = self.tokenizer
        tokens = [t.bos_id(), *t.encode(prefix + text, out_type=int)[:254], t.eos_id()]
        tokens += [t.pad_id()] * (256 - len(tokens))
        self.inputs[0].write(self.np.asarray(tokens, dtype=self.np.int32))
        self.model.run_by_index(0, self.inputs, self.outputs)
        vector = self.outputs[0].read(768, self.np.float32)
        norm = self.np.linalg.norm(vector)
        if not self.np.isfinite(vector).all() or not 0.99 <= norm <= 1.01:
            raise ValueError('invalid embedding output')
        return (vector / norm).tolist()

    def close(self):
        for buffer in (*self.inputs, *self.outputs):
            buffer.destroy()
