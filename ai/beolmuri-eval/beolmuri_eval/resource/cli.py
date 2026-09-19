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
from .summary import save_summary
from .provision import provision_model


def add_parser(commands):
    parser=commands.add_parser('resource',help='iOS RAM·전력 실험')
    sub=parser.add_subparsers(dest='resource_action',required=True)
    build=sub.add_parser('build',help='별도 추론 벤치마크 앱 빌드; 기본은 unsigned')
    build.add_argument('--signed',action='store_true')
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
    for name in ('status','cancel','collect','summarize'):
        command=sub.add_parser(name);command.add_argument('directory')
        if name=='cancel':command.add_argument('--after-ms',type=int,default=0)
    compare=sub.add_parser('compare');compare.add_argument('baseline');compare.add_argument('candidate')
    compare.add_argument('--allow',action='append',default=[],help='달라도 되는 명시적 필드 경로')
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
    if action=='agentctl':
        from ..cli import parser
        return dispatch(parser().parse_args(['resource',*args.arguments]))
    if action=='build':
        result=build_app(signed=args.signed,progress=Progress())
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
    elif action=='compare':result=compare_runs(resolve(args.baseline),resolve(args.candidate),allowed=args.allow)
    else:
        root=resolve(args.directory)
        if action=='status':
            result=dict(host_owner_active=active(root),last_recorded=read_json(root/'host-state.json')
                        if (root/'host-state.json').exists() else {},live_device_observation=False)
        elif action=='summarize':
            result,folder=save_summary(root);result={**result,'analysis':str(folder)}
        elif action=='collect':
            state=collect_run(root,device_for(root));summary,folder=save_summary(root)
            result=dict(device_state=state,summary=summary,analysis=str(folder))
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
