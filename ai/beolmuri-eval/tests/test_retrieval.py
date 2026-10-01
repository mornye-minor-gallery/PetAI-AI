import hashlib
import json
import struct
import tempfile
import unittest
from pathlib import Path
from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from beolmuri_eval.process import Worker
from beolmuri_eval.reaction_build import compile_rows


class RetrievalTests(unittest.TestCase):
    def test_resume_accepts_content_and_index_snapshots_and_detects_tampering(self):
        from beolmuri_eval.evaluation import verify_snapshot
        with tempfile.TemporaryDirectory() as d:
            inputs = Path(d) / 'inputs'; inputs.mkdir()
            metadata = {}
            for name in ['config.yaml', 'dataset.jsonl', 'judge.md', 'judge.schema.json',
                         'character.yaml', 'situation.yaml', 'reaction-frames.json',
                         'reaction-vectors.f32', 'dialogue-lore.json']:
                (inputs / name).write_bytes(b'fixture')
                metadata[name] = {'sha256': hashlib.sha256(b'fixture').hexdigest()}
            verify_snapshot(d, metadata)
            (inputs / 'reaction-vectors.f32').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'snapshot changed'):
                verify_snapshot(d, metadata)

    def test_skips_nonready_and_invalid_without_semantic_dedup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'rows.jsonl'
            frame = {'goal': 'g', 'shape': 's', 'search': ['a'], 'example': {'user': 'u', 'assistant': 'a'}}
            path.write_text('\n'.join(json.dumps(x) for x in [
                {'status': 'ready', 'source_id': '1', 'frame': frame},
                {'status': 'ready', 'source_id': '2', 'frame': frame},
                {'status': 'hold'}, {'status': 'ready', 'frame': {}}]))
            frames, rows, texts, skipped = compile_rows(path)
            self.assertEqual(len(frames), 2)
            self.assertEqual(rows, [0, 1])
            self.assertEqual(len(skipped), 2)

    def test_shared_worker_retrieves_one_and_lore_can_be_disabled(self):
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d)
            vector = struct.pack('<2f', 1, 0)
            (directory / 'reaction-vectors.f32').write_bytes(vector)
            (directory / 'reaction-frames.json').write_text(json.dumps({
                'version': 1, 'characterID': 'test', 'embeddingIdentity': 'fixture', 'dimension': 2,
                'vectorsSHA256': hashlib.sha256(vector).hexdigest(), 'rows': [0],
                'frames': [{'id': 'selected', 'goal': '상대의 이야기를 듣는다', 'shape': '짧게 답한다',
                            'example': {'user': '안녕', 'assistant': '{{user}}, 반가워.'}}]}))
            (directory / 'dialogue-lore.json').write_text(json.dumps({
                'tokenBudget': 200, 'scanDepth': 3, 'entries': [{'id': 'lore', 'keys': ['별'], 'content': '별길 정보'}]}))
            config = {'includePersona': True, 'includeSessionContext': True, 'enforceCharacterName': False,
                      'memoryClassification': False, 'dialogueContent': {'id': 'test', 'name': '검사자', 'persona': '친구처럼 답한다.',
                      'retrieval': {'reactions': True, 'worldLore': True}}}
            requests = []
            def embed(request):
                requests.append(request['text']); return {'vector': [1, 0], 'identity': 'fixture'}
            def measure(request):
                return len(request['text']) if request['measurement'] == 'count_tokens' else 500
            with Worker([str(swift_binary(repository()))], directory/'worker.log') as worker:
                args = dict(configuration=config, retrievalDirectory=d, characterName='검사자',
                            userMessage='별 이야기 해줘', history=[{'user': '안녕', 'assistant': '반가워'}],
                            tokenBudget={'memoryTokens': 100, 'contextTokens': 8096, 'outputTokens': 1024},
                            measurerID='fixture', measurement_handler=measure, embedding_handler=embed)
                result = worker.call('prepare', **args)
                self.assertEqual(requests, ['안녕\n반가워\n별 이야기 해줘'])
                self.assertEqual(result['retrieval_trace']['selected_id'], 'selected')
                self.assertIn('상대의 이야기를 듣는다', result['user_prompt'])
                self.assertIn('별길 정보', result['system_prompt'])
                self.assertNotIn('{{user}}', result['user_prompt'])
                config['dialogueContent']['retrieval']['worldLore'] = False
                result = worker.call('prepare', **args)
                self.assertNotIn('별길 정보', result['system_prompt'])
                self.assertIn('상대의 이야기를 듣는다', result['user_prompt'])
                config['dialogueContent']['retrieval']['reactions'] = False
                result = worker.call('prepare', **args)
                self.assertNotIn('상대의 이야기를 듣는다', result['user_prompt'])
                self.assertEqual(len(requests), 2)
                config['dialogueContent']['retrieval']['reactions'] = True
                with self.assertRaisesRegex(RuntimeError, 'embeddingMismatch'):
                    worker.call('prepare', **{**args, 'embedding_handler': lambda r: {'vector': [1, 0], 'identity': 'wrong'}})
                # An input error must not kill or desynchronize the worker.
                result = worker.call('prepare', **args)
                self.assertEqual(result['retrieval_trace']['selected_id'], 'selected')
