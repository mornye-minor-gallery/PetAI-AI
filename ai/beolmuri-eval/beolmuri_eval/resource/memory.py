"""Observed process footprint is not an activation-memory measurement."""
from .metrics import metric


def analyze_turn(samples, turn_id, *, max_gap_ns):
    rows = [r for r in samples if r.get('turn_id') == turn_id]
    starts = [r for r in rows if r.get('boundary') == 'turn_start']
    ends = [r for r in rows if r.get('boundary') == 'turn_end']
    reason = None
    interval = {'turn_id': turn_id}
    values = {}
    gap = None
    if len(starts) != 1 or len(ends) != 1:
        reason = 'missing_or_duplicate_ram_boundary'
    else:
        start, end = int(starts[0]['monotonic_ns']), int(ends[0]['monotonic_ns'])
        interval.update(start_ns=str(start), end_ns=str(end))
        rows = [r for r in rows if start <= int(r['monotonic_ns']) <= end]
        times = [int(r['monotonic_ns']) for r in rows]
        seq = [r['seq'] for r in rows]
        if end < start or any(b < a for a, b in zip(times, times[1:])):
            reason = 'invalid_ram_timeline'
        elif any(b != a + 1 for a, b in zip(seq, seq[1:])):
            reason = 'ram_sequence_gap'
        elif any(r.get('status') != 'ok' or type(r.get('bytes')) is not int or r['bytes'] < 0 for r in rows):
            reason = 'ram_sample_failed'
        else:
            gap = max((b - a for a, b in zip(times, times[1:])), default=0)
            if gap > max_gap_ns: reason = 'ram_sampling_gap'
            else:
                before, after = starts[0]['bytes'], ends[0]['bytes']
                peak = max(r['bytes'] for r in rows)
                values = dict(before=before, peak=peak, extra=peak-before, after=after)
    return {**{k: metric(values.get(k), 'bytes', 'task_info:phys_footprint', interval, reason)
               for k in ('before', 'peak', 'extra', 'after')},
            'max_gap_ns': gap, 'sample_count': len(rows)}
