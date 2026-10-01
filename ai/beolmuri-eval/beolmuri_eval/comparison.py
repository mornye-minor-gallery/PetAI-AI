"""Describe experimental differences; only corrupt evidence is a hard error."""
from pathlib import Path
from .metrics import summarize, compare_results, indexed
from .judge import validate_judgment
from .storage import read_json, records


def differences(a, b, path=''):
    if a == b:
        return []
    if isinstance(a, dict) and isinstance(b, dict):
        return [item for key in sorted(a.keys() | b.keys())
                for item in differences(a.get(key), b.get(key), f'{path}.{key}' if path else key)]
    return [{'field': path, 'baseline': a, 'candidate': b}]


def checked_records(directory, manifest):
    expected = {f"{case['id']}-r{repeat}": (case, repeat)
                for repeat in range(manifest['repeats']) for case in manifest['cases']}
    if len(expected) != len(manifest['cases']) * manifest['repeats']:
        raise ValueError('duplicate manifest case id')
    rows = indexed(records(directory))
    for key, row in rows.items():
        if key not in expected or (row['case'], row['repeat']) != expected[key]:
            raise ValueError(f'record conflicts with manifest: {key}')
        if row['status'] not in {'pending', 'prepared', 'generated', 'completed', 'graded', 'judge_error', 'generation_error'}:
            raise ValueError(f'unknown record status: {key}')
        if row['status'] == 'graded':
            validate_judgment(row['judgment'], row['generation']['processed']['visible_text'],
                              row['case']['kind'], manifest.get('judge', {}).get('output_schema'))
    return rows


def compare(left, right):
    directories = [Path(left), Path(right)]
    manifests = [read_json(path/'manifest.json') for path in directories]
    first, second = manifests
    a, b = [checked_records(path, manifest) for path, manifest in zip(directories, manifests)]
    summaries = [summarize(list(rows.values()), len(manifest['cases']) * manifest['repeats'],
                          planned_judgments=sum(c['kind'] != 'dialogue' for c in manifest['cases']) * manifest['repeats'])
                 for rows, manifest in zip((a,b), manifests)]
    # These fields change the meaning of the score. They do not prevent independent summaries.
    scoring_fields = ('provider', 'model', 'reasoning_effort', 'cli_version', 'rubric', 'output_schema', 'rubric_sha256', 'schema_sha256')
    same_scoring = all(first.get('judge', {}).get(k) == second.get('judge', {}).get(k) for k in scoring_fields)
    matched, excluded = [], []
    identity_fields = ('kind', 'character_name', 'called_name', 'user_message')
    for key in sorted(a.keys() | b.keys()):
        if key not in a or key not in b:
            reason = 'missing_result'
        elif a[key]['status'] != 'graded' or b[key]['status'] != 'graded':
            reason = 'not_both_graded'
        elif any(a[key]['case'].get(k) != b[key]['case'].get(k) for k in identity_fields):
            reason = 'different_evaluation_target'
        elif not same_scoring:
            reason = 'different_judge_contract'
        else:
            matched.append(key)
            continue
        excluded.append({'key':key, 'reason':reason})
    paired = {'available':bool(matched), 'matched':len(matched), 'matched_wrong_name':sum(a[k]['case']['kind'] == 'wrong_name' for k in matched), 'excluded':excluded,
              'scope':'matched graded targets only; inspect differences and coverage before interpretation'}
    if matched:
        paired.update(compare_results([a[k] for k in matched], [b[k] for k in matched]))
    def delta(x, y):
        return round(y-x, 3) if x is not None and y is not None and same_scoring else None
    # Run IDs and timestamps are also visible in the diff; no whitelist of allowed axes.
    return {'baseline':first['run_id'], 'candidate':second['run_id'],
            'differences':differences(first, second), 'same_scoring':same_scoring,
            'wrong_name_delta_percentage_points':{k:delta(summaries[0]['wrong_name'][k], summaries[1]['wrong_name'][k])
                for k in summaries[0]['wrong_name'] if k.endswith('_pct')},
            'control_correction_delta_percentage_points':delta(summaries[0]['correct_name']['incorrect_correction_pct'], summaries[1]['correct_name']['incorrect_correction_pct']),
            'paired':paired, 'summaries':summaries,
            'same_source':first.get('source_sha256') == second.get('source_sha256')}
