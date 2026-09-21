"""Portable evidence from recorded data, without local paths or judge CLI logs."""
import hashlib
import json
from pathlib import Path
from .comparison import compare, checked_records
from .metrics import summarize, numeric_summary
from .storage import read_json, atomic_json
from .evaluation import verify_snapshot


def portable_provenance(value, field):
    # Only transport/provenance fields contain machine-local paths. Dialogue text
    # beginning with '/' is evidence, not a filename, and must remain verbatim.
    parts = field.split('.')
    local = field in ('litert_python', 'model.path', 'judge.codex')
    local |= field.startswith('input_files.') and field.endswith('.source')
    local |= field.startswith('evaluation_config.') and (
        parts[-1] in ('path', 'history_file', 'memories_file', 'rubric', 'schema') or 'lorebooks' in parts)
    if local:
        return '<local-reference>' if value is not None else None
    if isinstance(value, dict):
        return {k:portable_provenance(v, field + '.' + k if field else k) for k,v in value.items()}
    if isinstance(value, list):
        return [portable_provenance(v, field) for v in value]
    return value


def portable_comparison(comparison):
    return {**comparison, 'differences':[
        {**item, 'baseline':portable_provenance(item['baseline'],item['field']),
         'candidate':portable_provenance(item['candidate'],item['field'])}
        for item in comparison['differences']]}


def export_run(directory, destination, name):
    manifest = read_json(directory/'manifest.json')
    verify_snapshot(directory, manifest['input_files'])
    rows = sorted(checked_records(directory, manifest).values(), key=lambda r:r['key'])
    allowed = ('key','case','repeat','status','input','generation','judgment','seeds',
               'session_before_sha256','session_after_sha256','session_after')
    clean = [{key:row[key] for key in allowed if key in row} for row in rows]
    (destination/(name+'.jsonl')).write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in clean))
    evidence_keys = ('run_id','variant','source_commit','source_sha256','dataset_sha256','configuration',
                     'scope','seed_policy','base_seed','runtime','prompt_budget','history_sha256','memories_sha256')
    evidence = {key:manifest[key] for key in evidence_keys if key in manifest}
    evidence['model'] = {key:value for key,value in manifest.get('model',{}).items() if key != 'path'}
    evidence['judge'] = {key:value for key,value in manifest['judge'].items() if key != 'codex'}
    evidence['input_hashes'] = {key:value['sha256'] for key,value in manifest['input_files'].items()}
    judged = sum(c['kind'] != 'dialogue' for c in manifest['cases'])
    evidence['summary'] = summarize(rows,len(manifest['cases'])*manifest['repeats'], judged*manifest['repeats'])
    evidence['per_repeat'] = {str(repeat):summarize([r for r in rows if r['repeat']==repeat],len(manifest['cases']),judged)
                              for repeat in range(manifest['repeats'])}
    evidence['primary_latency_ms'] = numeric_summary([r.get('generation',{}).get('primary',{}).get('elapsed_ms') for r in rows])
    evidence['retry_count'] = sum(r.get('generation',{}).get('retry') is not None for r in rows)
    return evidence


def export(before, after, destination):
    comparison = compare(before,after)
    destination.mkdir(parents=True,exist_ok=False)
    evidence = [export_run(path,destination,name) for path,name in ((before,'baseline'),(after,'candidate'))]
    atomic_json(destination/'comparison.json',portable_comparison(comparison))
    atomic_json(destination/'evidence.json',evidence)
    lines=['# 이름 평가 비교 결과','','| 조건 | 채점 완료 | 정정 | 정상 이름 오정정 |','| --- | ---: | ---: | ---: |']
    for name, item in zip(('기준','비교'),evidence):
        summary=item['summary'];wrong=summary['wrong_name'];correct=summary['correct_name']
        lines.append(f"| {name} | {summary['graded']}/{summary['planned_judgments']} | {wrong['counts']['identity_maintained']}/{wrong['denominator']} | {correct['incorrect_corrections']}/{correct['denominator']} |")
    lines += ['', f"짝 비교 가능한 채점 응답: {comparison['paired']['matched']}건.",
              '조건 차이와 제외된 응답은 comparison.json에서 확인한다. 다른 조건을 비교했다고 해서 원인이 분리된 것은 아니다.',
              '반복 번호와 실제 시드는 다르다. 시드 정책은 evidence.json, 턴별 실제 시드는 JSONL에 기록한다.',
              '과거 실행에서 seeds 필드가 없으면 해당 실행의 seed_policy를 따른다.',
              '생성 시간은 native generate 구간이며 준비·채점 시간을 포함하지 않는다.',
              '이 결과는 이름 평가이며 자연스러움이나 실제 기기 동작을 입증하지 않는다.','']
    (destination/'README.md').write_text('\n'.join(lines))
    atomic_json(destination/'checksums.json',{p.name:hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(destination.iterdir()) if p.is_file() and p.name!='checksums.json'})
