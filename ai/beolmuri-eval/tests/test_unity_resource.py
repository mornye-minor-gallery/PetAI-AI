import json
from pathlib import Path
import tempfile
import unittest
from uuid import uuid4
from beolmuri_eval.resource.unity import validate_plan, summarize, collect

class UnityResourceTests(unittest.TestCase):
    def plan(self):
        return dict(schema_version=1,run_id=str(uuid4()),character_id='elena',player_name='테스터',
                    thinking_enabled=False,ram_sample_period_ms=50,reply_gap_ms=1000,timeout_ms=120000,
                    inputs=[dict(id='hello',prompt='안녕?')])
    def test_actual_app_inputs_have_no_reconstructed_system_prompt(self):
        self.assertEqual(validate_plan(self.plan())['character_id'],'elena')
        p=self.plan();p['inputs'][0]['system_prompt']='replacement'
        with self.assertRaises(ValueError):validate_plan(p)
        p=self.plan();p['inputs']*=2
        with self.assertRaises(ValueError):validate_plan(p)
        p=self.plan();p['ram_sample_period_ms']=True
        with self.assertRaises(ValueError):validate_plan(p)
    def test_dead_process_collection_keeps_partial_samples(self):
        from beolmuri_eval.resource.protocol import sha256
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);plan=self.plan()
            (root/'manifest.json').write_text(json.dumps(plan))
            data=b'{"seq":0,"monotonic_ns":"100","bytes":123,"status":"ok","boundary":"session.token_count.begin"}\n'
            index=dict(run_id=plan['run_id'],complete=False,files=[dict(path='raw/ram.jsonl',kind='ram',bytes=len(data),sha256=sha256(data))])
            state=dict(run_id=plan['run_id'],phase='recording',pid=7,heartbeat_seq=3,last_stage='session.token_count.begin')
            class Device:
                def copy_from(self,src,dst):
                    dst=Path(dst);dst.parent.mkdir(parents=True,exist_ok=True)
                    dst.write_bytes(data if src.endswith('ram.jsonl') else json.dumps(index if src.endswith('artifacts.json') else state).encode())
                def processes(self):return {'runningProcesses':[]}
            result=collect(root,Device())
            self.assertFalse(result['complete'])
            self.assertEqual(result['process_observation'],'pid_absent')
            self.assertEqual(result['observed_peak_bytes'],123)
            self.assertFalse(result['power_measured'])
    def test_stage_spikes_are_not_called_pure_activation_memory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'raw').mkdir()
            (root/'artifacts.json').write_text(json.dumps(dict(complete=False,files=[dict(kind='ram',path='raw/ram.jsonl'),dict(kind='events',path='raw/events.jsonl')])))
            (root/'raw/ram.jsonl').write_text('\n'.join(json.dumps(dict(seq=i,monotonic_ns=str(i*100),bytes=b,status='ok')) for i,b in enumerate([100,200,150])))
            (root/'raw/events.jsonl').write_text('\n'.join(json.dumps(dict(kind=k,monotonic_ns=str(t),payload={})) for k,t in [('token_measure.begin',0),('token_measure.exit',200)]))
            result=summarize(root)
            self.assertEqual(result['observed_peak_bytes'],200)
            self.assertEqual(result['stages'][0]['delta_bytes'],50)
            self.assertEqual(result['stages'][0]['observed_peak_bytes'],200)
            self.assertFalse(result['complete'])

    def test_summary_exposes_real_prompt_inputs_and_cache_prefixes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'raw').mkdir()
            events=[
                dict(kind='capture.begin',monotonic_ns='50',payload={}),
                dict(kind='turn_start',monotonic_ns='100',payload=dict(turn_id='first')),
                dict(kind='dialogue.input',monotonic_ns='200',payload=dict(
                    request_id='request-1',scene='general',system_sha256='system-a',user_sha256='user-a',
                    system_bytes='5000',user_bytes='400',world_info_scanned_messages='1',
                    input_tokens='1500',history_messages='0',recalled_memory_count='2',inserted_memory_count='2',
                    world_info_configured='true',world_info_selected_ids='["lore.one"]',
                    world_info_inserted_ids='["lore.one"]',sections='[{"id":"persona","tokens":700}]')),
                dict(kind='session.submit.begin',monotonic_ns='300',payload=dict(
                    session_id='cached-1',input_tokens='1500',matching_input_prefix_tokens='0')),
                dict(kind='session.submit.exit',monotonic_ns='350',payload=dict(session_id='cached-1')),
                dict(kind='turn_end',monotonic_ns='400',payload=dict(turn_id='first')),
                dict(kind='turn_start',monotonic_ns='500',payload=dict(turn_id='second')),
                dict(kind='dialogue.input',monotonic_ns='600',payload=dict(
                    request_id='request-2',scene='general',system_sha256='system-a',user_sha256='user-b',
                    input_tokens='1600',history_messages='2',recalled_memory_count='2',inserted_memory_count='2',
                    world_info_configured='true',world_info_selected_ids='["lore.one"]',
                    world_info_inserted_ids='["lore.one"]',sections='[{"id":"persona","tokens":700}]')),
                dict(kind='session.submit.begin',monotonic_ns='700',payload=dict(
                    session_id='cached-1',input_tokens='1600',matching_input_prefix_tokens='1300')),
                dict(kind='session.submit.exit',monotonic_ns='750',payload=dict(session_id='cached-1')),
                dict(kind='native.inference',monotonic_ns='760',payload=dict(
                    request_id='request-2',benchmark_scope='primary',retry_attempted='false',
                    prefill_tokens='300',prefill_tokens_per_second='150.5',decode_tokens='24',
                    decode_tokens_per_second='12.25',first_response_seconds='2.5',
                    generation_elapsed_seconds='4.0')),
                dict(kind='turn_end',monotonic_ns='800',payload=dict(turn_id='second')),
                dict(kind='capture.end',monotonic_ns='900',payload={}),
            ]
            (root/'raw/events.jsonl').write_text('\n'.join(json.dumps(row) for row in events))
            (root/'raw/ram.jsonl').write_text('')
            (root/'artifacts.json').write_text(json.dumps(dict(complete=True,files=[
                dict(kind='events',path='raw/events.jsonl'),dict(kind='ram',path='raw/ram.jsonl')])))
            (root/'device-state-final.json').write_text(json.dumps(dict(phase='finished')))
            result=summarize(root)
            self.assertEqual(result['prompt_observations'][0]['scene'],'general')
            self.assertEqual(result['prompt_observations'][0]['system_bytes'],5000)
            self.assertEqual(result['prompt_observations'][0]['world_info_scanned_messages'],1)
            self.assertEqual(result['prompt_observations'][0]['world_info_selected_ids'],['lore.one'])
            self.assertEqual(result['prompt_observations'][0]['sections'],[dict(id='persona',tokens=700)])
            self.assertEqual(result['cache_submissions'][1]['matching_input_prefix_tokens'],1300)
            self.assertEqual(result['cache_submissions'][1]['session_id'],'cached-1')
            self.assertEqual(result['cache_session_count'],1)
            self.assertTrue(result['single_cached_session'])
            self.assertAlmostEqual(result['cache_submissions'][1]['matching_input_prefix_ratio'],1300/1600)
            self.assertEqual(result['native_inference'][0],dict(
                request_id='request-2',benchmark_scope='primary',retry_attempted=False,
                prefill_tokens=300,prefill_tokens_per_second=150.5,decode_tokens=24,
                decode_tokens_per_second=12.25,first_response_seconds=2.5,
                generation_elapsed_seconds=4.0,turn_id='second'))
            self.assertEqual(result['unfinished_stages'],[])
            self.assertEqual(next(row for row in result['stages'] if row['stage']=='capture')['duration_ms'],0.00085)

class UnityResourceRunnerTests(unittest.TestCase):
    def test_launch_transport_failure_still_attempts_collection(self):
        from unittest.mock import patch
        from beolmuri_eval.resource.unity import run
        class Phone:
            def __init__(self,*args,**kwargs):pass
            def apps(self):return {'apps':[{'bundleIdentifier':'test.app'}]}
            def details(self):return {'hardwareProperties':{'udid':'synthetic-device'}}
            def copy_to(self,*args,**kwargs):pass
            def launch(self,*args):raise RuntimeError('launch response lost')
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=UnityResourceTests().plan();del p['run_id']
            config=root/'config.json';config.write_text(json.dumps(p))
            with patch('beolmuri_eval.resource.unity.repository',return_value=root), \
                 patch('beolmuri_eval.resource.unity.UnityDevice',Phone), \
                 patch('beolmuri_eval.resource.unity.collect',return_value={'complete':False}) as collector:
                result=run(config,device_id='synthetic',bundle='test.app')
            collector.assert_called_once()
            self.assertFalse(result['complete'])
            self.assertIn('launch response lost',result['host_error'])

    def test_example_is_valid_under_shared_schema(self):
        from beolmuri_eval.config import repository
        from beolmuri_eval.resource.config import validate_document
        root=repository()/'contracts/resource-benchmark'
        plan=json.loads((root/'examples/unity-diagnostic.json').read_text())
        validate_document('unity-diagnostic',plan)
        validate_plan(dict(plan,run_id=str(uuid4())))
