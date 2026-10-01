"""Run one owned tool with durable logs and a periodic host heartbeat."""
import json
from pathlib import Path
import subprocess
import time
from uuid import uuid4
from ..storage import atomic_json


def run_tool(argv, directory, *, timeout=60, progress=lambda **kw: None):
    directory = Path(directory) / str(uuid4())
    directory.mkdir(parents=True)
    atomic_json(directory / 'command.json', {'argv': [str(v) for v in argv]})
    with (directory/'stdout.log').open('wb') as out, (directory/'stderr.log').open('wb') as err:
        process = subprocess.Popen([str(v) for v in argv], stdin=subprocess.DEVNULL, stdout=out, stderr=err)
        start = time.monotonic()
        try:
            while process.poll() is None:
                elapsed = time.monotonic()-start
                if elapsed >= timeout: raise TimeoutError(f'tool timeout; logs: {directory}')
                progress(stage='tool', elapsed_seconds=elapsed, pid=process.pid)
                try: process.wait(timeout=min(5, timeout-elapsed))
                except subprocess.TimeoutExpired: continue
        except BaseException:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
            atomic_json(directory/'result.json', {'exit_code': process.returncode, 'interrupted': True})
            raise
    atomic_json(directory/'result.json', {'exit_code': process.returncode, 'elapsed_seconds': time.monotonic()-start})
    if process.returncode: raise RuntimeError(f'tool failed ({process.returncode}); logs: {directory}')
    return directory
