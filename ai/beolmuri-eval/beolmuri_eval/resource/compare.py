"""Compare explicit axes only, keeping the paired device-wide interpretation."""
from pathlib import Path
import statistics
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
        conditions.append(flattened(dict(measurement_mode=manifest.get('measurement_mode','power'),
                          config=config,model=manifest['model'],generation=manifest['generation'],
                          inputs=manifest['inputs'],device=transport['device'],build_id=transport['expected_build_id'],environment=summary['measurement_environment'])))
    differing={key:{'baseline':conditions[0].get(key),'candidate':conditions[1].get(key)}
               for key in conditions[0].keys()|conditions[1].keys() if conditions[0].get(key)!=conditions[1].get(key)}
    if set(allowed)-conditions[0].keys():raise ValueError('unknown ablation axis')
    unexpected=set(differing)-set(allowed)
    if unexpected:raise ValueError('comparison conditions differ: '+', '.join(sorted(unexpected)))
    modes=[read_json(root/'manifest.json').get('measurement_mode','power') for root in roots]
    if modes[0]!=modes[1]:raise ValueError('comparison measurement modes differ')
    if modes[0]=='inference':
        names=('first_response_seconds','generation_elapsed_seconds','prefill_tokens_per_second')
        inference={}
        common=sorted(set(metrics[0]['native_inference'])&set(metrics[1]['native_inference']))
        if not common:raise ValueError('inference comparison has no shared turn IDs')
        for name in names:
            pairs=[]
            for turn_id in common:
                values=[metric['native_inference'][turn_id].get(name,{}) for metric in metrics]
                if all(value.get('status')=='ok' for value in values):
                    pairs.append((turn_id,values[0]['value'],values[1]['value']))
            if not pairs:continue
            baseline_values=[row[1] for row in pairs];candidate_values=[row[2] for row in pairs]
            inference[name]=dict(
                baseline=statistics.fmean(baseline_values),candidate=statistics.fmean(candidate_values),
                delta=statistics.fmean(candidate_values)-statistics.fmean(baseline_values),
                turns={turn_id:dict(baseline=before,candidate=after,delta=after-before)
                       for turn_id,before,after in pairs})
        peaks=[]
        for turn_id in common:
            values=[metric['turns'].get(turn_id,{}).get('peak',{}) for metric in metrics]
            if all(value.get('status')=='ok' for value in values):
                peaks.append((turn_id,values[0]['value'],values[1]['value']))
        if peaks:
            before=[row[1] for row in peaks];after=[row[2] for row in peaks]
            inference['peak_ram_bytes']=dict(baseline=statistics.fmean(before),candidate=statistics.fmean(after),
                                             delta=statistics.fmean(after)-statistics.fmean(before),
                                             turns={turn:dict(baseline=a,candidate=b,delta=b-a)
                                                    for turn,a,b in peaks})
        return dict(measurement_mode='inference',baseline=metrics[0]['run_id'],candidate=metrics[1]['run_id'],
                    differences=differing,inference=inference,
                    interpretation='same-device exact-turn inference latency and process footprint')
    values=[m['power']['mean']['value'] for m in metrics]
    return dict(measurement_mode='power',baseline=metrics[0]['run_id'],candidate=metrics[1]['run_id'],differences=differing,
                power=dict(unit='%/hr',baseline=values[0],candidate=values[1],delta=values[1]-values[0]),
                interpretation='device-wide difference; includes application and system activity')
