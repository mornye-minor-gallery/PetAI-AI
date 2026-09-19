"""Only devicectl's structured file is used as an application-control result."""
import json
import math
from pathlib import Path
from uuid import uuid4
from ..storage import read_json
from .tools import run_tool
from .config import validate_document

ROOT = 'Library/Application Support/ResourceBench'

class Device:
    def __init__(self, identifier, bundle, directory, *, progress=lambda **kw: None):
        if not bundle.endswith('.resourcebench'): raise ValueError('a separate .resourcebench bundle is required')
        self.identifier, self.bundle = identifier, bundle
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.progress = progress

    def call(self, arguments, *, timeout=60):
        output = self.directory/(str(uuid4())+'.json')
        argv = ['xcrun','devicectl',*arguments[:3],'--device',self.identifier,
                '--timeout',str(math.ceil(timeout)),'--json-output',str(output),*arguments[3:]]
        run_tool(argv,self.directory/'tools',timeout=timeout+5,progress=self.progress)
        value = read_json(output)
        if value.get('info',{}).get('outcome') != 'success':
            raise RuntimeError(f'device operation not confirmed: {output}')
        return value['result']

    def details(self): return self.call(['device','info','details'])
    def apps(self): return self.call(['device','info','apps'])
    def processes(self): return self.call(['device','info','processes'])
    def copy_to(self, source, destination, *, timeout=300):
        return self.call(['device','copy','to','--source',str(source),'--destination',destination,
                          '--domain-type','appDataContainer','--domain-identifier',self.bundle],timeout=timeout)
    def copy_from(self, source, destination, *, timeout=60):
        Path(destination).parent.mkdir(parents=True,exist_ok=True)
        return self.call(['device','copy','from','--source',source,'--destination',str(destination),
                          '--domain-type','appDataContainer','--domain-identifier',self.bundle],timeout=timeout)
    def launch(self, run_id):
        # Never use --terminate-existing; a previous owned process is reconciled first.
        return self.call(['device','process','launch','--environment-variables',
                          json.dumps({'RESOURCE_BENCH_RUN_ID':run_id}),self.bundle])
    def state(self, run_id):
        path=self.directory/(str(uuid4())+'-state.json')
        self.copy_from(f'{ROOT}/runs/{run_id}/state.json',path)
        return validate_document("state", read_json(path))
    def terminate_owned(self, state):
        pid=state['pid']
        rows=self.processes().get('runningProcesses')
        if not isinstance(rows,list): raise RuntimeError('process inventory format unverified')
        matches=[r for r in rows if r.get('processIdentifier')==pid]
        if not matches: return {'termination':'confirmed','evidence':'pid_absent'}
        # Re-read the live mailbox. A heartbeat must advance before terminating a
        # PID: an old completed checkpoint alone cannot prove current ownership.
        fresh=self.state(state['run_id'].lower())
        if (fresh['process_instance_id']!=state['process_instance_id'] or fresh['pid']!=pid
            or fresh['heartbeat_seq']<=state['heartbeat_seq']):
            raise RuntimeError('process ownership freshness unconfirmed')
        self.call(['device','process','terminate','--pid',str(pid)])
        if any(r.get('processIdentifier')==pid for r in self.processes()['runningProcesses']):
            raise RuntimeError('app termination unconfirmed')
        return {'termination':'confirmed','evidence':'owned_pid_terminated'}
