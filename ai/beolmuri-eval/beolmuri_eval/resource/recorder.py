"""xctrace ownership, real Darwin start notification, and bounded finalization."""
import ctypes
import os
import xml.etree.ElementTree as ET
from pathlib import Path
import signal
import subprocess
import time
from uuid import uuid4
from ..storage import atomic_json
from .tools import run_tool


class StartedSignal:
    def __init__(self, name):
        self.name = name
        self.library = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        self.library.notify_register_check.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int)]
        self.library.notify_check.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
        self.library.notify_cancel.argtypes = [ctypes.c_int]
        self.library.notify_post.argtypes = [ctypes.c_char_p]
        self.token = ctypes.c_int()
    def __enter__(self):
        if self.library.notify_register_check(self.name.encode(), ctypes.byref(self.token)):
            raise RuntimeError('cannot register recorder start notification')
        self.received()  # Drain registration state BEFORE launching xctrace.
        return self
    def received(self):
        value = ctypes.c_int()
        if self.library.notify_check(self.token, ctypes.byref(value)): raise RuntimeError('notification check failed')
        return bool(value.value)
    def post_for_test(self):
        if self.library.notify_post(self.name.encode()): raise RuntimeError('notification post failed')
    def __exit__(self, *args):
        if self.library.notify_cancel(self.token): raise RuntimeError('notification cancellation failed')


class Recorder:
    def __init__(self, directory, *, progress=lambda **kw: None):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.trace = self.directory/'capture.trace'
        self.process = None
        self.progress = progress
        self.logs = []
        self.stopped_by_host = None

    def start(self, *, device, pid, limit_ms, timeout=60):
        if self.trace.exists(): raise ValueError('trace already exists; append is not allowed')
        name = 'org.petai.resourcebench.started.'+str(uuid4())
        with StartedSignal(name) as started:
            argv = ['xcrun','xctrace','record','--device',device,'--all-processes',
                    '--instrument','Power Profiler','--instrument','os_signpost',
                    '--notify-tracing-started',name,'--time-limit',f'{limit_ms}ms','--output',str(self.trace)]
            self.logs = [(self.directory/(s+'.log')).open('wb') for s in ('stdout','stderr')]
            self.process = subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=self.logs[0],stderr=self.logs[1])
            atomic_json(self.directory/'process.json',dict(pid=self.process.pid,argv=argv,phase='starting',expected_app_pid=pid))
            deadline = time.monotonic()+timeout
            while not started.received():
                if self.process.poll() is not None: raise RuntimeError('recorder exited before start notification')
                if time.monotonic() >= deadline: raise TimeoutError('recorder start unconfirmed')
                self.progress(stage='recorder_start',pid=self.process.pid)
                time.sleep(0.25)
            atomic_json(self.directory/'started.json',dict(pid=self.process.pid,notification=name))

    def stop(self, *, timeout):
        if self.process is None: return
        if self.stopped_by_host is None:
            self.stopped_by_host = self.process.poll() is None
            if self.stopped_by_host: self.process.send_signal(signal.SIGINT)
            atomic_json(self.directory/'stop-request.json',dict(stopped_by_host=self.stopped_by_host))
        stopped_by_host = self.stopped_by_host
        deadline = time.monotonic()+timeout
        while self.process.poll() is None:
            if time.monotonic() >= deadline:
                # Do not silently kill a recorder that may still be saving the only trace.
                atomic_json(self.directory/'result.json',dict(termination='unconfirmed',pid=self.process.pid))
                raise TimeoutError('recorder finalization unconfirmed; owned process and logs preserved')
            self.progress(stage='recorder_saving',pid=self.process.pid)
            time.sleep(0.5)
        if self.process.stdin: self.process.stdin.close()
        for handle in self.logs: handle.close()
        atomic_json(self.directory/'result.json',dict(exit_code=self.process.returncode,
                    stopped_by_host=stopped_by_host,termination='confirmed',target_scope='all_processes'))
        if self.process.returncode or not self.trace.is_dir(): raise RuntimeError('recorder failed to save trace')
        return stopped_by_host

    def export(self):
        exports=[('toc.xml',['--toc'])]
        exports += [(name,['--xpath',f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'])
                    for schema,name in [('SystemPowerLevel','power.xml'),('os-signpost-interval','signposts.xml')]]
        for name,selection in exports:
            destination=self.directory/name
            if destination.exists():
                ET.parse(destination)
                continue
            pending=self.directory/(str(uuid4())+'.partial.xml')
            run_tool(['xcrun','xctrace','export','--input',self.trace,*selection,'--output',pending],
                     self.directory/'tools',progress=self.progress)
            ET.parse(pending)
            with pending.open('rb') as handle:os.fsync(handle.fileno())
            os.link(pending,destination)
