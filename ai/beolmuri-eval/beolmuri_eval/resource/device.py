"""Only devicectl's structured file is used as an application-control result."""
import json
import math
from pathlib import Path
import tempfile
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
    def lock_state(self): return self.call(['device','info','lockState'])
    def apps(self): return self.call(['device','info','apps'])
    def processes(self): return self.call(['device','info','processes'])
    def copy_to(self, source, destination, *, timeout=300):
        return self.call(['device','copy','to','--source',str(source),'--destination',destination,
                          '--domain-type','appDataContainer','--domain-identifier',self.bundle],timeout=timeout)
    def copy_from(self, source, destination, *, timeout=60):
        Path(destination).parent.mkdir(parents=True,exist_ok=True)
        return self.call(['device','copy','from','--source',source,'--destination',str(destination),
                          '--domain-type','appDataContainer','--domain-identifier',self.bundle],timeout=timeout)
    def probe_transport(self):
        """Prove the app-data file channel before starting a benchmark."""
        nonce=str(uuid4())
        with tempfile.TemporaryDirectory(prefix='beolmuri-transport-') as temporary:
            source=Path(temporary)/'probe.json';destination=Path(temporary)/'roundtrip.json'
            source.write_text(json.dumps({'nonce':nonce}))
            remote=f'{ROOT}/preflight/{nonce}.json'
            self.copy_to(source,remote)
            self.copy_from(remote,destination)
            if read_json(destination).get('nonce')!=nonce:
                raise RuntimeError('filesandbox roundtrip mismatch')
        return {'status':'ready','nonce':nonce}
    def running_app_processes(self):
        apps=self.apps().get('apps',[])
        app=next((row for row in apps if row.get('bundleIdentifier')==self.bundle),None)
        if app is None:return []
        url=app.get('url','')
        prefix=url.removeprefix('file://').rstrip('/')+'/'
        rows=self.processes().get('runningProcesses')
        if not isinstance(rows,list):raise RuntimeError('process inventory format unverified')
        return [row for row in rows if isinstance(row.get('executable'),str)
                and row['executable'].startswith(prefix)]
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
