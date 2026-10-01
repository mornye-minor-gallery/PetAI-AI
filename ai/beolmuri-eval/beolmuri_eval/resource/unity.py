"""RAM-only diagnostics of the production Unity conversation path; no model substitution."""
import json
from pathlib import Path
import re
import time
from uuid import UUID, uuid4
from ..config import repository
from ..storage import atomic_json, read_json, run_lock
from .collection import collect_files
from .device import Device, ROOT
from .runner import Progress


def validate_plan(plan):
    keys={'schema_version','run_id','character_id','player_name','thinking_enabled','ram_sample_period_ms',
          'reply_gap_ms','timeout_ms','inputs'}
    if set(plan)!=keys or type(plan['schema_version']) is not int or plan['schema_version']!=1:raise ValueError('invalid unity diagnostic fields')
    if str(UUID(plan['run_id']))!=plan['run_id']:raise ValueError('invalid run id')
    if any(not isinstance(plan[k],str) or not plan[k].strip() for k in ('character_id','player_name')):
        raise ValueError('character_id and player_name are required')
    if type(plan['thinking_enabled']) is not bool:raise ValueError('thinking_enabled must be boolean')
    for key,lo,hi in [('ram_sample_period_ms',10,10000),('reply_gap_ms',0,60000),('timeout_ms',1000,3600000)]:
        if type(plan[key]) is not int or not lo<=plan[key]<=hi:raise ValueError('invalid '+key)
    rows=plan['inputs']
    if not isinstance(rows,list) or not 1<=len(rows)<=100:raise ValueError('one to 100 inputs required')
    if any(not isinstance(row,dict) or set(row)!={'id','prompt'} or
           any(not isinstance(v,str) or not v.strip() for v in row.values()) for row in rows):
        raise ValueError('Unity input requires id and prompt; app assembles its own system prompt')
    if len({r['id'] for r in rows})!=len(rows):raise ValueError('duplicate turn id')
    return plan


class UnityDevice(Device):
    def __init__(self, identifier, bundle, directory, *, progress=lambda **kw:None):
        # Opt-in diagnostic target only. The inference benchmark's separate-bundle guard stays intact.
        if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',bundle):raise ValueError('invalid app bundle')
        self.identifier,self.bundle=identifier,bundle
        self.directory=Path(directory);self.directory.mkdir(parents=True,exist_ok=True)
        self.progress=progress
    def launch(self,run_id):
        return self.call(['device','process','launch','--environment-variables',
                          json.dumps({'RESOURCE_UNITY_RUN_ID':run_id}),self.bundle])
    def diagnostic_state(self,run_id):
        path=self.directory/(str(uuid4())+'-state.json')
        self.copy_from(f'{ROOT}/unity/{run_id}/state.json',path)
        state=read_json(path)
        if state.get('run_id')!=run_id or state.get('target')!='unity':raise ValueError('diagnostic run mismatch')
        return state


def summarize(root):
    root=Path(root);index=read_json(root/'artifacts.json')
    rows={'ram':[],'events':[]}
    for entry in index['files']:
        if entry['kind'] not in rows:continue
        rows[entry['kind']].extend(json.loads(line) for line in (root/entry['path']).read_text().splitlines() if line)
    samples=sorted((r for r in rows['ram'] if r.get('status')=='ok' and isinstance(r.get('bytes'),int)),
                   key=lambda r:int(r['monotonic_ns']))
    events=sorted(rows['events'],key=lambda r:int(r['monotonic_ns']))
    stages=[];opened={};live_sessions=set();peak_sessions=0;created=0
    for event in events:
        kind=event['kind'];ns=int(event['monotonic_ns']);payload=event.get('payload',{})
        session_id=payload.get('session_id')
        if kind=='session.created':
            created+=1;live_sessions.add(session_id);peak_sessions=max(peak_sessions,len(live_sessions))
        elif kind=='session.delete.exit':live_sessions.discard(session_id)
        if kind.endswith('.begin'):opened[(kind[:-6],payload.get('session_id'))]=ns
        elif kind.endswith('.exit') or kind.endswith('.end'):
            key=(kind.rsplit('.',1)[0],payload.get('session_id'));start=opened.pop(key,None)
            if start is None:continue
            before=next((r for r in reversed(samples) if int(r['monotonic_ns'])<=start),None)
            in_stage=([before] if before else [])+[r for r in samples if start<int(r['monotonic_ns'])<=ns]
            stages.append(dict(stage=key[0],session_id=key[1],duration_ms=(ns-start)/1e6,
                observed_peak_bytes=max((r['bytes'] for r in in_stage),default=None),
                delta_bytes=in_stage[-1]['bytes']-in_stage[0]['bytes'] if len(in_stage)>1 else None))
    state=read_json(root/'device-state-final.json') if (root/'device-state-final.json').exists() else {}
    turns=[e for e in events if e['kind']=='turn_start']
    completed=[e for e in events if e['kind']=='turn_end']
    def payloads(kind,*,integers=(),floats=(),booleans=(),json_fields=()):
        values=[]
        for event in events:
            if event['kind']!=kind:continue
            value=dict(event.get('payload',{}))
            for key in integers:
                if key in value:value[key]=int(value[key])
            for key in floats:
                if key in value:value[key]=float(value[key])
            for key in booleans:
                if key in value:value[key]=str(value[key]).lower()=='true'
            for key in json_fields:
                if key in value:value[key]=json.loads(value[key])
            values.append(value)
        return values
    prompt_observations=payloads('dialogue.input',
        integers=('input_tokens','system_bytes','user_bytes','history_messages','recalled_memory_count',
                  'inserted_memory_count','world_info_scanned_messages'),
        booleans=('world_info_configured',),
        json_fields=('world_info_selected_ids','world_info_inserted_ids','sections'))
    cache_submissions=payloads('session.submit.begin',
        integers=('input_tokens','matching_input_prefix_tokens'))
    for submission in cache_submissions:
        input_tokens=submission.get('input_tokens',0)
        matching_tokens=submission.get('matching_input_prefix_tokens',0)
        submission['matching_input_prefix_ratio']=matching_tokens/input_tokens if input_tokens else None
    cache_session_count=len({row['session_id'] for row in cache_submissions if row.get('session_id')})
    native_inference=payloads('native.inference',
        integers=('prefill_tokens','decode_tokens'),
        floats=('prefill_tokens_per_second','decode_tokens_per_second',
                'first_response_seconds','generation_elapsed_seconds'),
        booleans=('retry_attempted',))
    native_events=[event for event in events if event['kind']=='native.inference']
    for observation,event in zip(native_inference,native_events,strict=True):
        timestamp=int(event['monotonic_ns'])
        prior=[turn for turn in turns if int(turn['monotonic_ns'])<=timestamp]
        observation['turn_id']=prior[-1].get('payload',{}).get('turn_id') if prior else None
    timings=[]
    for turn in turns:
        start=int(turn['monotonic_ns']);following=next((int(e['monotonic_ns']) for e in turns if int(e['monotonic_ns'])>start),None)
        first=next((int(e['monotonic_ns']) for e in events if e['kind']=='dialogue.first_output' and int(e['monotonic_ns'])>=start
                    and (following is None or int(e['monotonic_ns'])<following)),None)
        end=next((int(e['monotonic_ns']) for e in completed if e.get('payload',{}).get('turn_id')==turn.get('payload',{}).get('turn_id')),None)
        timings.append(dict(turn_id=turn.get('payload',{}).get('turn_id'),
                            first_output_event_ms=(first-start)/1e6 if first else None,
                            duration_ms=(end-start)/1e6 if end else None))
    return dict(complete=index.get('complete',False) and state.get('phase')=='finished',target='unity',profile='unity-memory',
        prompt_observations=prompt_observations,cache_submissions=cache_submissions,
        native_inference=native_inference,
        cache_session_count=cache_session_count,single_cached_session=cache_session_count==1,
        memory_metric='phys_footprint',power_measured=False,observed_peak_bytes=max((r['bytes'] for r in samples),default=None),
        sample_count=len(samples),completed_turns=len(completed),turns=timings,stages=stages,
        wrapper_sessions_created=created,observed_live_wrappers_peak=peak_sessions,live_wrapper_ids=sorted(live_sessions),
        unfinished_stages=[dict(stage=k[0],session_id=k[1]) for k in opened],
        last_stage=state.get('last_stage'),error=state.get('error'),
        interpretation='Process footprint and observed samples; not pure activation memory or proof of a native KV copy.')


def collect(root,device):
    root=Path(root);plan=read_json(root/'manifest.json');base=f"{ROOT}/unity/{plan['run_id']}"
    transfers=root/'transfers';transfers.mkdir(exist_ok=True)
    state_path=transfers/(str(uuid4())+'-state.json')
    device.copy_from(base+'/state.json',state_path);state=read_json(state_path)
    if state.get('run_id')!=plan['run_id']:raise ValueError('collection run mismatch')
    atomic_json(root/'device-state-final.json',state)
    index_path=transfers/(str(uuid4())+'-artifacts.json')
    device.copy_from(base+'/artifacts.json',index_path);index=read_json(index_path)
    if index['run_id']!=plan['run_id']:raise ValueError('artifact run mismatch')
    collect_files(root,index,lambda p,d:device.copy_from(base+'/'+p,d))
    atomic_json(root/'artifacts.json',index)
    result=summarize(root)
    try:
        rows=device.processes().get('runningProcesses')
        if not isinstance(rows,list):raise ValueError('process inventory unavailable')
        # PID presence alone does not establish ownership or responsiveness.
        result['process_observation']='pid_present_identity_unverified' if any(r.get('processIdentifier')==state['pid'] for r in rows) else 'pid_absent'
    except Exception as error:result['process_observation']='unknown';result['observation_error']=str(error)
    folder=root/'analysis'/str(uuid4());folder.mkdir(parents=True)
    atomic_json(folder/'summary.json',result)
    return dict(result,analysis=str(folder))


def run(config_path,*,device_id,bundle):
    progress=Progress();plan=read_json(Path(config_path))
    if 'run_id' in plan:raise ValueError('run_id is assigned for each execution; omit it from config')
    plan=validate_plan(dict(plan,run_id=str(uuid4())))
    root=repository()/'ai/beolmuri-eval/.artifacts/unity-resource-runs'/plan['run_id'];root.mkdir(parents=True)
    atomic_json(root/'manifest.json',plan)
    atomic_json(root/'transport.json',dict(device=device_id,bundle=bundle))
    device=UnityDevice(device_id,bundle,root/'device',progress=progress)
    apps=device.apps()
    if not any(a.get('bundleIdentifier')==bundle for a in apps.get('apps',[])):raise ValueError('app not installed')
    deadline=time.monotonic()+plan['timeout_ms']/1000+60
    last_seq=None;changed_at=time.monotonic()
    # This does not kill, reset, sign, or install the user's app.
    details=device.details()
    canonical=details.get('hardwareProperties',{}).get('udid')
    if not canonical:raise ValueError('canonical device identity unavailable')
    from .protocol import sha256
    device.identifier=canonical
    atomic_json(root/'device-info.json',details)
    atomic_json(root/'transport.json',dict(device=canonical,bundle=bundle))
    ownership=root.parent.parent/'resource-devices'/sha256(canonical.lower().encode())
    ownership.mkdir(parents=True,exist_ok=True)
    with run_lock(ownership), run_lock(root):
        active=ownership/'active.json'
        if active.exists() and not read_json(active).get('termination_confirmed',False):
            raise ValueError('another resource experiment has unconfirmed ownership; reconcile it first')
        run_error=None
        try:
            device.copy_to(root/'manifest.json',f"{ROOT}/unity/{plan['run_id']}/manifest.json")
            atomic_json(root/'launch.json',device.launch(plan['run_id']))
            while time.monotonic()<deadline:
                if (root/'cancel.request').exists():
                    device.copy_to(root/'cancel.request',f"{ROOT}/unity/{plan['run_id']}/cancel.request")
                try:state=device.diagnostic_state(plan['run_id'])
                except (RuntimeError,TimeoutError) as error:
                    progress(stage='await_unity_capture',error=str(error),directory=str(root));time.sleep(2);continue
                atomic_json(root/'device-state-final.json',state)
                seq=state.get('heartbeat_seq')
                if seq!=last_seq:last_seq=seq;changed_at=time.monotonic()
                done=state.get('completed_turns',0);total=len(plan['inputs']);filled=int(20*done/total)
                progress(stage=state.get('last_stage'),phase=state['phase'],directory=str(root),heartbeat=seq,
                         progress_bar='['+'#'*filled+'-'*max(0,20-filled)+f'] {done}/{total}')
                if state['phase'] in {'finished','failed'}:break
                if time.monotonic()-changed_at>15:
                    rows=device.processes().get('runningProcesses',[])
                    if not any(r.get('processIdentifier')==state.get('pid') for r in rows):break
                time.sleep(2)
            else:
                run_error='capture_timeout'
                atomic_json(root/'host-error.json',dict(error='capture_timeout; app completion unverified'))
                atomic_json(root/'cancel.request',dict(run_id=plan['run_id']))
                device.copy_to(root/'cancel.request',f"{ROOT}/unity/{plan['run_id']}/cancel.request")
        except KeyboardInterrupt:
            run_error='cancel_requested'
            atomic_json(root/'cancel.request',dict(run_id=plan['run_id']))
            device.copy_to(root/'cancel.request',f"{ROOT}/unity/{plan['run_id']}/cancel.request")
        except Exception as error:
            run_error=str(error)
            atomic_json(root/'host-error.json',dict(error=run_error))
        finally:
            # Collection does not require a completed turn, receipt, or live app.
            try:result=collect(root,device)
            except Exception as error:
                result=dict(complete=False,error=str(error),hint='Measurement build required; launch a fresh process and reach the Home screen.')
            if run_error:result=dict(result,complete=False,host_error=run_error)
            atomic_json(root/'host-result.json',result)
    return dict(result,directory=str(root))
