"""Synthetic app records + real export shapes, never a device benchmark result."""
import json
from pathlib import Path
from beolmuri_eval.resource.protocol import sha256
RUN='00000000-0000-0000-0000-000000000001'
OWNER='00000000-0000-0000-0000-000000000002'
FIXTURES=Path(__file__).parent/'fixtures/resource'


def app_files():
 samples=[dict(seq=i,monotonic_ns=str(i*100_000_000),bytes=value,status='ok',boundary=boundary,
               **({'turn_id':'turn'} if i>=2 else {}))
          for i,(value,boundary) in enumerate([(10,'model_before'),(100,'model_after'),
               (100,'turn_start'),(150,None),(120,'turn_end')])]
 condition=dict(foreground=True,charging='unplugged',brightness=0.5,thermal='nominal')
 events=[dict(kind='conditions',payload=condition),
         dict(kind='window_start',payload={'signpost_before_ns':'1000','signpost_after_ns':'1100'}),
         dict(kind='conditions',payload=condition),
         dict(kind='window_end',payload={'signpost_before_ns':'2008748958','signpost_after_ns':'2008749058'})]
 for i,event in enumerate(events):event.update(run_id=RUN,seq=i)
 files={'raw/000000-ram.jsonl':b''.join(json.dumps(r).encode()+b'\n' for r in samples),
        'raw/000001-events.jsonl':b''.join(json.dumps(r).encode()+b'\n' for r in events)}
 index=dict(schema_version=1,run_id=RUN,complete=True,files=[dict(path=name,kind='ram' if 'ram' in name else 'events',
            bytes=len(data),sha256=sha256(data),complete=True) for name,data in files.items()])
 files['artifacts.json']=json.dumps(index).encode()
 return files


def recorder_files(root):
 root.mkdir(parents=True,exist_ok=True)
 for name in ('power.xml','signposts.xml'):(root/name).write_bytes((FIXTURES/name).read_bytes())
 (root/'toc.xml').write_text('<trace-toc><run number="1"><info><target><device model="synthetic" os-version="synthetic" /></target><summary><instruments-version>synthetic</instruments-version><end-reason>User pressed Stop</end-reason></summary></info></run></trace-toc>')
 (root/'result.json').write_text(json.dumps(dict(exit_code=0,termination='confirmed',stopped_by_host=True)))
