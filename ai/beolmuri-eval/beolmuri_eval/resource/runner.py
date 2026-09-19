"""One owner per phone; no automatic experiment retry or resume."""
import json
from pathlib import Path
import plistlib
import sys
import time
from uuid import uuid4
from ..config import repository
from ..storage import atomic_json, read_json, run_lock
from .collection import collect_files
from .device import Device, ROOT
from .observation import Observation
from .plan import inputs_from_config, manifest, verify_model
from .protocol import command_bytes, sha256
from .recorder import Recorder
from .summary import save_summary


class Progress:
    def __init__(self): self.last=0;self.stage=None
    def __call__(self, **value):
        now=time.monotonic()
        if now-self.last>=5 or value.get('stage')!=self.stage:
            if 'planned_runs' in value:
                total=value['planned_runs'];done=value['completed_runs'];filled=int(20*done/total)
                value['progress_bar']='['+'#'*filled+'-'*(20-filled)+f'] {done}/{total}'
            print(json.dumps(value,ensure_ascii=False),file=sys.stderr,flush=True)
            self.last=now;self.stage=value.get('stage')


def send_command(device, root, plan, state, operation):
    command=dict(schema_version=1,run_id=plan['run_id'],owner_id=plan['owner_id'],
                 operation_id=str(uuid4()),expected_revision=state['revision'],operation=operation,
                 payload={'manifest_sha256':sha256((root/'manifest.json').read_bytes())})
    name,data=command_bytes(command)
    local=root/'commands'/name;local.parent.mkdir(exist_ok=True);local.write_bytes(data)
    device.copy_to(local,f"{ROOT}/runs/{plan['run_id']}/commands/{name}")
    return command


def collect_run(root, device):
    root=Path(root);plan=read_json(root/'manifest.json')
    state=device.state(plan['run_id'])
    if state['run_id'].lower()!=plan['run_id']:raise ValueError('collection run mismatch')
    atomic_json(root/'device-state-final.json',state)
    temporary=root/'transfers'/f'{uuid4()}-artifacts.json';temporary.parent.mkdir(exist_ok=True)
    device.copy_from(f"{ROOT}/runs/{plan['run_id']}/artifacts.json",temporary)
    index=read_json(temporary)
    if index['run_id'].lower()!=plan['run_id']:raise ValueError('artifact index run mismatch')
    collect_files(root,index,lambda path,dest:device.copy_from(f"{ROOT}/runs/{plan['run_id']}/{path}",dest))
    atomic_json(root/'artifacts.json',index)
    receipts=[]
    for path in sorted((root/'commands').glob('*.json')):
        command=read_json(path);operation_id=command['operation_id']
        pending=root/'transfers'/f'{uuid4()}-receipt.json'
        device.copy_from(f"{ROOT}/runs/{plan['run_id']}/receipts/{operation_id}.json",pending)
        receipt=read_json(pending)
        if receipt['digest']!=sha256(path.read_bytes()):raise ValueError('command receipt hash mismatch')
        receipts.append(dict(command=command,receipt=receipt))
    atomic_json(root/'command-receipts.json',receipts)
    return state


def wait_phase(device, root, plan, phases, *, timeout, observer, progress):
    deadline=time.monotonic()+timeout
    last_error=None
    while time.monotonic()<deadline:
        if (root/'cancel.request').exists():raise InterruptedError('cancellation_requested')
        try:
            state=device.state(plan['run_id'])
        except (RuntimeError,TimeoutError) as error:
            last_error=str(error)
            atomic_json(root/'host-state.json',dict(observation='unknown',error=last_error))
        else:
            observation=observer.observe(state,now=time.monotonic())
            atomic_json(root/'host-state.json',observation)
            if state['phase'] in {'failed','cancelled'}:raise RuntimeError('app ended: '+str(state.get('error',state['phase'])))
            if state['phase'] in phases and observation['observation']=='known':return state
            last_error='device phase: '+state['phase']
        progress(stage='await_app',run_id=plan['run_id'],expected=sorted(phases),last=last_error)
        time.sleep(min(5,max(0,deadline-time.monotonic())))
    raise TimeoutError('app phase unconfirmed: '+str(last_error))


def run_one(root, plan, device, expected_build, *, progress, model_source=None):
    root=Path(root);config=plan['config'];run_id=plan['run_id']
    root.mkdir(parents=True)
    atomic_json(root/'manifest.json',plan)
    atomic_json(root/'transport.json',dict(device=device.identifier,bundle=device.bundle,expected_build_id=expected_build))
    observer=Observation(run_id=run_id,owner_id=plan['owner_id'])
    recorder=Recorder(root/'recorder',progress=progress)
    last=None; launched=False; failure=None; termination=False
    with run_lock(root):
        try:
            device.copy_to(root/'manifest.json',f'{ROOT}/runs/{run_id}/manifest.json')
            launched=True  # A timeout after dispatch does not prove that launch did not occur.
            launch=device.launch(run_id);atomic_json(root/'launch.json',launch)
            last=wait_phase(device,root,plan,{'boot_ready'},timeout=60,observer=observer,progress=progress)
            if last.get('build_id')!=expected_build or last.get('bundle_id')!=device.bundle:
                raise RuntimeError('installed benchmark build does not match expected build identity')
            if model_source is not None:
                device.copy_to(model_source,f"{ROOT}/{plan['model']['path']}",timeout=config['prepare_timeout_ms']/1000)
            if (root/'cancel.request').exists():raise InterruptedError('cancellation_requested')
            limit=sum(config[k] for k in ('prepare_timeout_ms','power_window_ms','turn_timeout_ms',
                                          'recorder_pre_roll_ms','recorder_post_roll_ms'))+60_000
            inventory=device.processes()
            atomic_json(root/'processes-before-recording.json',inventory)
            rows=inventory.get('runningProcesses')
            if not isinstance(rows,list) or not any(r.get('processIdentifier')==last['pid'] for r in rows):
                raise RuntimeError('app PID absent from live process inventory before recording')
            # Power is device-wide. Capture globally, then bind app signposts to
            # the exact owned PID/run ID during analysis; never substitute another app.
            recorder.start(device=device.identifier,pid=last['pid'],limit_ms=limit)
            send_command(device,root,plan,last,'prepare')
            last=wait_phase(device,root,plan,{'ready'},timeout=config['prepare_timeout_ms']/1000+10,
                            observer=observer,progress=progress)
            if (root/'cancel.request').exists():raise InterruptedError('cancellation_requested')
            send_command(device,root,plan,last,'begin')
            last=wait_phase(device,root,plan,{'finished'},timeout=(config['power_window_ms']+config['turn_timeout_ms']+
                            config['recorder_pre_roll_ms']+config['recorder_post_roll_ms'])/1000+15,
                            observer=observer,progress=progress)
            stopped=recorder.stop(timeout=config['finalize_timeout_ms']/1000)
            if not stopped:raise RuntimeError('recorder stopped before planned host stop')
            recorder.export()
            last=collect_run(root,device)
            result,_=save_summary(root)
            if not result['complete']:raise RuntimeError('required measurement evidence invalid')
        except (Exception,KeyboardInterrupt) as error:
            failure=str(error) or type(error).__name__
            atomic_json(root/'failure.json',dict(reason=failure))
            # Reconciliation never sends a second begin. Errors here are preserved
            # independently so they cannot replace the original experiment failure.
            try:
                last=device.state(run_id)
                if last['phase'] not in {'finished','failed','cancelled'}:
                    send_command(device,root,plan,last,'cancel')
            except Exception as reconciliation:
                atomic_json(root/'cancel-error.json',dict(error=str(reconciliation)))
            if recorder.process is not None:
                try:recorder.stop(timeout=config['finalize_timeout_ms']/1000)
                except Exception as stop_error:atomic_json(root/'recorder-stop-error.json',dict(error=str(stop_error)))
            try: last=collect_run(root,device)
            except Exception as collection_error:atomic_json(root/'collection-error.json',dict(error=str(collection_error)))
        # Keep terminal heartbeats alive on the app until its own process is stopped.
        if last and last['phase'] in {'finished','failed','cancelled'}:
            try:
                deadline=time.monotonic()+15
                observed=last
                while time.monotonic()<deadline:
                    current=device.state(run_id)
                    if current['heartbeat_seq']>observed['heartbeat_seq']:break
                    time.sleep(1)
                device.terminate_owned(observed)
                termination=True
            except Exception as error:atomic_json(root/'termination-error.json',dict(error=str(error)))
        elif not launched:termination=True
        recorder_terminated=recorder.process is None or recorder.process.poll() is not None
        app_terminated=termination
        termination=app_terminated and recorder_terminated
        atomic_json(root/'termination.json',dict(confirmed=termination,app_confirmed=app_terminated,
                                                 recorder_confirmed=recorder_terminated))
        result,analysis=save_summary(root)
        complete=result['complete'] and failure is None and termination
        final=dict(phase='completed' if complete else 'failed',observation='known' if termination else 'unknown',
                   termination_confirmed=termination,reason=failure,analysis=str(analysis))
        atomic_json(root/'host-state.json',final)
        return dict(run_id=run_id,directory=str(root),complete=complete,**final)


def run_batch(config_path, *, device_id, app_path, model_preinstalled=False):
    config,paths,model,model_path,generation,rows=inputs_from_config(config_path)
    app=Path(app_path).resolve();info=plistlib.loads((app/'Info.plist').read_bytes())
    build_id=info.get('ResourceBenchBuildID')
    if not build_id or info['CFBundleIdentifier']!=config['bundle_id']:raise ValueError('a matching benchmark .app is required')
    base=repository()/'ai/beolmuri-eval/.artifacts/resource-runs'
    batch=base/str(uuid4());batch.mkdir(parents=True)
    owner=str(uuid4());progress=Progress()
    device=Device(device_id,config['bundle_id'],batch/'device',progress=progress)
    details=device.details();atomic_json(batch/'device.json',details)
    canonical=details.get('hardwareProperties',{}).get('udid')
    if not canonical:raise RuntimeError('canonical hardware device identity unavailable')
    device.identifier=canonical
    device_directory=base.parent/'resource-devices'/sha256(canonical.lower().encode())
    device_directory.mkdir(parents=True,exist_ok=True)
    active=device_directory/'active.json'
    with run_lock(device_directory):
        if active.exists() and not read_json(active).get('termination_confirmed',False):
            raise RuntimeError('previous device owner has unconfirmed termination; inspect and collect that run first')
        if details.get('connectionProperties',{}).get('transportType')!='localNetwork':
            raise RuntimeError('power measurement requires an unplugged wireless connection')
        apps=device.apps();atomic_json(batch/'apps.json',apps)
        # Never infer installation from a successful build on this Mac.
        installed=apps.get('apps',[])
        if not any(a.get('bundleIdentifier')==config['bundle_id'] for a in installed):
            raise RuntimeError('benchmark app is not installed; connect the unlocked phone for installation')
        verify_model(model_path,model['sha256'],progress=progress)
        # Model upload happens outside every measured window. Content hash in the
        # path identifies it; the app independently hashes the received bytes.
        # Upload after the first app boot has disabled auto-lock, before recording.
        snapshots=batch/'inputs';snapshots.mkdir()
        for key,path in paths.items():(snapshots/(key+path.suffix)).write_bytes(path.read_bytes())
        atomic_json(batch/'inputs.json',dict(config=config,files={k:sha256(v.read_bytes()) for k,v in paths.items()},
                                           build_id=build_id,backend='cpu',model_preinstalled=model_preinstalled))
        results=[]
        for pair in range(config['pair_count']):
            for role in (['idle','work'] if pair%2==0 else ['work','idle']):
                plan=manifest(config,model,generation,rows,role=role,owner_id=owner)
                folder=batch/plan['run_id']
                atomic_json(active,dict(owner_id=owner,directory=str(folder),termination_confirmed=False))
                progress(stage='batch',pair=pair+1,pair_count=config['pair_count'],role=role,
                         completed_runs=len(results),planned_runs=config['pair_count']*2)
                result=run_one(folder,plan,device,build_id,progress=progress,model_source=model_path if not results and not model_preinstalled else None)
                results.append(result)
                atomic_json(active,dict(owner_id=owner,directory=str(folder),termination_confirmed=result['termination_confirmed']))
                atomic_json(batch/'state.json',dict(complete=False,results=results))
                if not result['complete']:return dict(batch=str(batch),complete=False,results=results)
        atomic_json(batch/'state.json',dict(complete=True,results=results))
        return dict(batch=str(batch),complete=True,results=results)
