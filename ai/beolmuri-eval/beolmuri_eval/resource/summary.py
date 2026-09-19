"""Re-derive metrics from sealed evidence; partial results never imply a complete run."""
from pathlib import Path
import json
import xml.etree.ElementTree as ET
from uuid import uuid4
from ..storage import atomic_json, read_json
from .collection import safe_relative
from .memory import analyze_turn
from .metrics import metric
from .power import read_power, analyze_power
from .protocol import sha256
from .signposts import window_from_trace


def summarize_run(directory):
    root=Path(directory)
    manifest=read_json(root/'manifest.json')
    config=manifest['config']
    reasons=[]; samples=[]; events=[]; source_hashes={}; environment={}
    state=read_json(root/'device-state-final.json') if (root/'device-state-final.json').exists() else {}
    if state.get('phase')!='finished': reasons.append('app_not_finished')
    try:
        receipts=read_json(root/'command-receipts.json')
        completed={r['command']['operation'] for r in receipts if r['receipt']['status']=='completed'}
        if not {'prepare','begin'} <= completed:reasons.append('command_completion_unconfirmed')
    except (OSError,ValueError,KeyError) as error:reasons.append('command_receipts_unavailable: '+str(error))
    try:
        index=read_json(root/'artifacts.json')
        if not index['complete']: reasons.append('app_artifacts_incomplete')
        seen=set()
        for entry in index['files']:
            path=str(safe_relative(entry['path']))
            if path in seen: raise ValueError('duplicate artifact path')
            seen.add(path)
            data=(root/path).read_bytes()
            if len(data)!=entry['bytes'] or sha256(data)!=entry['sha256']: raise ValueError('artifact hash mismatch')
            source_hashes[path]=entry['sha256']
            if entry['kind'] in {'ram','events'}:
                rows=[json.loads(line) for line in data.splitlines() if line]
                (samples if entry['kind']=='ram' else events).extend(rows)
    except (OSError, ValueError, KeyError) as error: reasons.append(str(error));samples=[];events=[]
    ids=list(dict.fromkeys(r['turn_id'] for r in samples if r.get('turn_id')))
    turns={key:analyze_turn(samples,key,max_gap_ns=config['ram_max_gap_ms']*1_000_000) for key in ids}
    model={}
    for name in ('model_before','model_after'):
        rows=[r for r in samples if r.get('boundary')==name]
        valid=len(rows)==1 and rows[0].get('status')=='ok' and type(rows[0].get('bytes')) is int
        model[name]=metric(rows[0]['bytes'] if valid else None,'bytes','task_info:phys_footprint',{},
                           None if valid else 'missing_or_invalid_model_boundary')
    if manifest['role']=='work' and not turns: reasons.append('no_completed_turns')
    if any(t['peak']['status']!='ok' for t in turns.values()): reasons.append('invalid_turn_ram')
    if any(m['status']!='ok' for m in model.values()): reasons.append('invalid_model_ram')
    power={'mean':metric(None,'%/hr','xctrace:SystemPowerLevel',{},'power_not_validated'),
           'consumption':metric(None,'% of total battery energy','xctrace:SystemPowerLevel',{},'power_not_validated')}
    try:
        recorder=read_json(root/'recorder/result.json')
        if recorder.get('termination')!='confirmed' or recorder.get('exit_code')!=0 or recorder.get('stopped_by_host') is not True:
            raise ValueError('planned recorder termination not confirmed')
        toc=ET.parse(root/'recorder/toc.xml')
        runs=toc.findall('run')
        if len(runs)!=1: raise ValueError('expected one trace run')
        reason=runs[0].findtext('info/summary/end-reason')
        device=runs[0].find('info/target/device')
        version=runs[0].findtext('info/summary/instruments-version')
        if device is None or not version:raise ValueError('trace environment missing')
        environment=dict(device_model=device.attrib['model'],device_os=device.attrib['os-version'],instruments_version=version,
                         recorder_target_scope=recorder.get('target_scope','unrecorded'))
        start,end=window_from_trace((root/'recorder/signposts.xml').read_bytes(),run_id=manifest['run_id'],pid=state['pid'])
        boundaries=[]
        for kind,trace_time in [('window_start',start),('window_end',end)]:
            rows=[e for e in events if e['kind']==kind]
            if len(rows)!=1: raise ValueError('missing or duplicate app window boundary')
            event=rows[0];payload=event['payload']
            if event['run_id'].lower()!=manifest['run_id'].lower(): raise ValueError('event run identity mismatch')
            before,after=int(payload['signpost_before_ns']),int(payload['signpost_after_ns'])
            if before>after: raise ValueError('invalid signpost clock bracket')
            boundaries.append((trace_time-after-1000,trace_time-before+1000))
        low=max(v[0] for v in boundaries);high=min(v[1] for v in boundaries)
        if low>high: raise ValueError('app and trace clocks do not align')
        # Keep exactly equal comparison windows. The end signpost confirms the app
        # reached the deadline; scheduler delay is recorded, not added to energy.
        requested_ns=config['power_window_ms']*1_000_000
        if end-start<requested_ns: raise ValueError('power window ended before planned deadline')
        conditions=[e['payload'] for e in events if e['kind']=='conditions']
        start_event=next(e for e in events if e['kind']=='window_start')
        before=[e['payload'] for e in events if e['kind']=='conditions' and e['seq']<start_event['seq']]
        if not before or before[-1]['thermal']!=config['required_initial_thermal_state']:
            raise ValueError('initial thermal condition not confirmed')
        environment['initial_thermal_state']=before[-1]['thermal']
        environment['applied_brightness']=before[-1]['brightness']
        if len(conditions)<2 or any(not c['foreground'] or c['charging']!='unplugged' for c in conditions):
            raise ValueError('foreground or charging evidence incomplete')
        if len({c['brightness'] for c in conditions})!=1: raise ValueError('brightness changed')
        power=analyze_power(read_power((root/'recorder/power.xml').read_bytes()),start,start+requested_ns,
                            end_reason=reason,charging='unplugged')
        power['alignment_offset_ns']=[str(low),str(high)]
        power['observed_signpost_duration_ns']=end-start
        power['conditions']=conditions
        for name in ('toc.xml','power.xml','signposts.xml'):
            source_hashes['recorder/'+name]=sha256((root/'recorder'/name).read_bytes())
        if power['mean']['status']!='ok': reasons.append(power['mean']['reason'])
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError) as error:
        reasons.append(str(error))
        power={key:metric(None,value['unit'],value['source'],{},str(error)) for key,value in power.items() if key in {'mean','consumption'}}
    for name in ('manifest.json','artifacts.json','device-state-final.json','command-receipts.json'):
        if (root/name).is_file():source_hashes[name]=sha256((root/name).read_bytes())
    return dict(schema_version=1,run_id=manifest['run_id'],complete=not reasons,reasons=reasons,
                calibration='unverified',measurement_environment=environment,model_ram=model,turns=turns,power=power,source_sha256=source_hashes)


def save_summary(directory):
    root=Path(directory);result=summarize_run(root)
    folder=root/'analyses'/str(uuid4());folder.mkdir(parents=True)
    atomic_json(folder/'summary.json',result)
    code={p.name:sha256(p.read_bytes()) for p in Path(__file__).parent.glob('*.py')}
    atomic_json(folder/'analysis.json',dict(code_sha256=code))
    (folder/'report.md').write_text('# 자원 측정 결과\n\n'+('필수 자료 검증 통과' if result['complete'] else '미완료 또는 무효')+'\n\n'
        +'실기기 수집 주기 교정: 미검증\n\n'+json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    return result,folder
