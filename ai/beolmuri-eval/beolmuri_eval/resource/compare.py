"""Compare explicit axes only, keeping the paired device-wide interpretation."""
from pathlib import Path
from ..storage import read_json
from .summary import summarize_run


def flattened(value, prefix=''):
    if isinstance(value,dict):
        result={}
        for key,child in value.items():result.update(flattened(child,prefix+'.'+key if prefix else key))
        return result
    return {prefix:value}


def compare_runs(baseline,candidate,*,allowed=()):
    roots=[Path(baseline),Path(candidate)]
    metrics=[summarize_run(p) for p in roots]
    if not all(m['complete'] for m in metrics):raise ValueError('comparison requires two complete valid runs')
    conditions=[]
    for root,summary in zip(roots,metrics):
        manifest=read_json(root/'manifest.json');transport=read_json(root/'transport.json')
        config={k:v for k,v in manifest['config'].items()
                if k not in {'fixture','initial_state','model_manifest','generation_config','pair_count'}}
        conditions.append(flattened(dict(config=config,model=manifest['model'],generation=manifest['generation'],
                          inputs=manifest['inputs'],device=transport['device'],build_id=transport['expected_build_id'],environment=summary['measurement_environment'])))
    differing={key:{'baseline':conditions[0].get(key),'candidate':conditions[1].get(key)}
               for key in conditions[0].keys()|conditions[1].keys() if conditions[0].get(key)!=conditions[1].get(key)}
    if set(allowed)-conditions[0].keys():raise ValueError('unknown ablation axis')
    unexpected=set(differing)-set(allowed)
    if unexpected:raise ValueError('comparison conditions differ: '+', '.join(sorted(unexpected)))
    values=[m['power']['mean']['value'] for m in metrics]
    return dict(baseline=metrics[0]['run_id'],candidate=metrics[1]['run_id'],differences=differing,
                power=dict(unit='%/hr',baseline=values[0],candidate=values[1],delta=values[1]-values[0]),
                interpretation='device-wide difference; includes application and system activity')
