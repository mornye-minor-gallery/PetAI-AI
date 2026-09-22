"""Resource CLI and agentctl share the same headless operations."""
import json
from pathlib import Path
import subprocess
import time
from uuid import uuid4
from ..config import repository
from ..storage import active,atomic_json,read_json
from .build import build_app
from .compare import compare_runs
from .device import Device
from .plan import inputs_from_config
from .runner import Progress,run_batch,collect_run,send_command
from .inference import recover_active_owner,resume_inference_run,run_inference_batch
from .protocol import sha256
from .summary import save_summary
from .provision import provision_model


def add_parser(commands):
    parser=commands.add_parser('resource',help='iOS RAM·전력 실험')
    sub=parser.add_subparsers(dest='resource_action',required=True)
    build=sub.add_parser('build',help='추론 단독 또는 Unity 측정 앱 빌드; 기본은 unsigned')
    build.add_argument('--signed',action='store_true')
    build.add_argument('--target',choices=['inference','unity'],default='inference')
    build.add_argument('--unity-editor');build.add_argument('--dialogue-content')
    doctor=sub.add_parser('doctor',help='기기·설치 앱 조회; 추론·측정 없음')
    doctor.add_argument('--device',required=True)
    doctor.add_argument('--bundle',default='com.mornye.EdgeLLMLab.resourcebench')
    doctor.add_argument('--json',action='store_true')
    validate=sub.add_parser('validate');validate.add_argument('--config',required=True)
    run=sub.add_parser('run');run.add_argument('--config',required=True);run.add_argument('--device',required=True)
    run.add_argument('--model-preinstalled',action='store_true',help='전송된 모델 사용; 앱의 SHA-256 검증은 유지')
    provision=sub.add_parser('provision',help='측정 없이 모델 전송·왕복 해시 검증')
    provision.add_argument('--config',required=True);provision.add_argument('--device',required=True)
    run.add_argument('--app',required=True,help='빌드 식별자를 대조할 .app 경로')
    inference=sub.add_parser('inference',help='전력 기록 없이 고정 입력을 정확히 한 번씩 추론')
    cache=sub.add_parser('kv-cache',help='같은 입력으로 fresh/cached 추론을 연속 비교')
    for command in (inference,cache):
        command.add_argument('--config',required=True)
        command.add_argument('--device',required=True)
        command.add_argument('--app',required=True,help='빌드 식별자를 대조할 .app 경로')
        command.add_argument('--model-preinstalled',action='store_true')
    inference.add_argument('--content',help='공용 Swift Composer에 넣을 dialogue-content.json')
    inference.add_argument('--turns',help='id, user_message, history를 가진 JSON/JSONL')
    cache.add_argument('--content',required=True,help='공용 Swift Composer에 넣을 dialogue-content.json')
    cache.add_argument('--turns',required=True,help='id, user_message, history를 가진 JSON/JSONL')
    for name in ('status','cancel','collect','summarize','resume','recover'):
        command=sub.add_parser(name);command.add_argument('directory')
        if name=='cancel':command.add_argument('--after-ms',type=int,default=0)
    compare=sub.add_parser('compare');compare.add_argument('baseline');compare.add_argument('candidate')
    compare.add_argument('--allow',action='append',default=[],help='달라도 되는 명시적 필드 경로')
    unity=sub.add_parser('unity',help='실제 Unity 앱 RAM 진단; RESOURCE_BENCH 빌드 필요')
    actions=unity.add_subparsers(dest='unity_action',required=True)
    u_run=actions.add_parser('run');u_run.add_argument('--config',required=True)
    u_run.add_argument('--device',required=True);u_run.add_argument('--bundle',default='com.byeolmuri.app')
    for name in ('status','collect','cancel','summarize'):
        actions.add_parser(name).add_argument('directory')
    agent=sub.add_parser('agentctl',help='같은 코어의 상태·취소·회수·실행 인터페이스')
    agent.add_argument('arguments',nargs='...')


def resolve(value):
    path=Path(value).expanduser().resolve()
    if not (path/'manifest.json').is_file():raise ValueError('resource run not found')
    return path


def device_for(root):
    transport=read_json(root/'transport.json')
    return Device(transport['device'],transport['bundle'],root/'reconciliation',progress=Progress())


def dispatch(args):
    action=args.resource_action
    if action=='unity':
        from .unity import run, UnityDevice, collect, summarize
        if args.unity_action=='run':result=run(args.config,device_id=args.device,bundle=args.bundle)
        else:
            root=resolve(args.directory);plan=read_json(root/'manifest.json');transport=read_json(root/'transport.json')
            device=UnityDevice(transport['device'],transport['bundle'],root/'device',progress=Progress())
            if args.unity_action=='collect':result=collect(root,device)
            elif args.unity_action=='summarize':result=summarize(root)
            elif args.unity_action=='status':result=dict(state=device.diagnostic_state(plan['run_id']),liveness_verified=False)
            else:
                from .device import ROOT
                atomic_json(root/'cancel.request',dict(run_id=plan['run_id']))
                device.copy_to(root/'cancel.request',f"{ROOT}/unity/{plan['run_id']}/cancel.request")
                result=dict(cancellation_requested=True,termination_confirmed=False)
        print(json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False))
        return 2 if result.get('complete') is False else 0
    if action=='agentctl':
        from ..cli import parser
        return dispatch(parser().parse_args(['resource',*args.arguments]))
    if action=='build':
        if args.target=='unity':
            if args.signed:raise ValueError('Unity signing uses scripts/upload-testflight-local.sh --resource-bench')
            if not args.unity_editor or not args.dialogue_content:raise ValueError('--unity-editor and --dialogue-content are required')
            from .unity_build import build_unity_app
            result=build_unity_app(unity_editor=args.unity_editor,dialogue_content=args.dialogue_content,progress=Progress())
        else:result=build_app(signed=args.signed,progress=Progress())
    elif action=='validate':
        config,paths,model,source,generation,rows=inputs_from_config(args.config)
        result=dict(valid=True,target=config['target'],profile=config['profile'],input_count=len(rows),
                    model_sha256=model['sha256'],model_content_verified=False)
    elif action=='doctor':
        folder=repository()/'ai/beolmuri-eval/.artifacts/resource-doctor'/str(uuid4())
        device=Device(args.device,args.bundle,folder,progress=Progress())
        details=device.details();apps=device.apps()
        atomic_json(folder/'device.json',details);atomic_json(folder/'apps.json',apps)
        installed=any(a.get('bundleIdentifier')==args.bundle for a in apps.get('apps',[]))
        result=dict(device_reachable=True,benchmark_installed=installed,ready=installed,
                    capture_verified=False,inference_verified=False,evidence=str(folder))
    elif action=='provision':
        result=provision_model(args.config,device_id=args.device,progress=Progress())
    elif action=='run':
        result=run_batch(args.config,device_id=args.device,app_path=args.app,model_preinstalled=args.model_preinstalled)
    elif action in {'inference','kv-cache'}:
        modes=('fresh_per_input',) if action=='inference' else ('fresh_per_input','cached_full_prompt')
        result=run_inference_batch(args.config,device_id=args.device,app_path=args.app,
                                   model_preinstalled=args.model_preinstalled,modes=modes,
                                   canonical_content=args.content,dialogue_turns=args.turns)
        if action=='kv-cache' and result['complete']:
            before,after=(Path(row['directory']) for row in result['results'])
            result['comparison']=compare_runs(before,after,allowed=['generation.conversation_mode'])
    elif action=='compare':result=compare_runs(resolve(args.baseline),resolve(args.candidate),allowed=args.allow)
    else:
        root=resolve(args.directory)
        if action=='status':
            result=dict(host_owner_active=active(root),last_recorded=read_json(root/'host-state.json')
                        if (root/'host-state.json').exists() else {},
                        control=read_json(root/'control-state.json') if (root/'control-state.json').exists() else None,
                        live_device_observation=False)
        elif action=='summarize':
            result,folder=save_summary(root);result={**result,'analysis':str(folder)}
        elif action=='collect':
            state=collect_run(root,device_for(root));summary,folder=save_summary(root)
            result=dict(device_state=state,summary=summary,analysis=str(folder))
        elif action=='resume':
            result=resume_inference_run(root,device_for(root),progress=Progress())
        elif action=='recover':
            device=device_for(root)
            device_directory=repository()/'ai/beolmuri-eval/.artifacts/resource-devices'/sha256(device.identifier.lower().encode())
            result=recover_active_owner(device_directory/'active.json',device,progress=Progress())
        elif action=='cancel':
            if args.after_ms<0:raise ValueError('after-ms must be nonnegative')
            deadline=time.monotonic()+args.after_ms/1000
            progress=Progress()
            while time.monotonic()<deadline:
                progress(stage='scheduled_cancel',remaining_seconds=deadline-time.monotonic())
                time.sleep(max(0,min(1,deadline-time.monotonic())))
            if active(root):
                atomic_json(root/'cancel.request',dict(requested=True))
                result=dict(cancellation_requested=True,termination_confirmed=False)
            else:
                device=device_for(root);plan=read_json(root/'manifest.json');state=device.state(plan['run_id'])
                command=send_command(device,root,plan,state,'cancel')
                result=dict(operation_id=command['operation_id'],cancellation_requested=True,termination_confirmed=False)
    print(json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False))
    return 2 if result.get('complete') is False or result.get('ready') is False else 0
