"""Read xctrace's typed XML and integrate intervals without imputing missing power."""
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
import xml.etree.ElementTree as ET
from .metrics import metric


@dataclass(frozen=True)
class PowerSample:
    start_ns: int
    duration_ns: int
    rate: Decimal


def read_power(data: bytes) -> list[PowerSample]:
    if b'<!DOCTYPE' in data or b'<!ENTITY' in data:
        raise ValueError('XML declarations are not supported')
    try:
        root = ET.fromstring(data)
        nodes = [n for n in root.findall('node') if n.find('schema') is not None
                 and n.find('schema').get('name') == 'SystemPowerLevel']
        if len(nodes) != 1:
            raise ValueError('expected exactly one SystemPowerLevel table')
        node = nodes[0]
        columns = [c.findtext('engineering-type') for c in node.find('schema').findall('col')]
        required = ['start-time', 'duration', 'percent-per-hour']
        if any(columns.count(c) != 1 for c in required):
            raise ValueError('unsupported power column types')
        identifiers = {}
        for element in root.iter():
            if 'id' in element.attrib:
                key = element.attrib['id']
                if key in identifiers: raise ValueError('duplicate XML id')
                identifiers[key] = element

        def resolve(element):
            seen = set()
            while 'ref' in element.attrib:
                key = element.attrib['ref']
                if key in seen or key not in identifiers: raise ValueError('unresolved XML reference')
                seen.add(key)
                target = identifiers[key]
                if target.tag != element.tag: raise ValueError('XML reference type mismatch')
                element = target
            return element.text

        # Even auxiliary columns must not contain broken cross-row references.
        for element in root.iter():
            if 'ref' in element.attrib: resolve(element)
        result = []
        for row in node.findall('row'):
            if [c.tag for c in row] != columns: raise ValueError('power row does not match schema')
            values = {c.tag: resolve(c) for c in row if c.tag in required}
            start, duration = int(values['start-time']), int(values['duration'])
            rate = Decimal(values['percent-per-hour'])
            if start < 0 or duration <= 0 or not rate.is_finite() or rate < 0:
                raise ValueError('invalid power interval or rate')
            result.append(PowerSample(start, duration, rate))
        return result
    except (ET.ParseError, TypeError, InvalidOperation, KeyError) as error:
        raise ValueError(f'invalid power export: {error}') from error


def analyze_power(rows, start_ns, end_ns, *, end_reason, charging,
                  boundary_tolerance_ns=1000):
    if not isinstance(start_ns, int) or not isinstance(end_ns, int) or end_ns <= start_ns:
        raise ValueError('power window must be a positive integer interval')
    interval = {'start_ns': str(start_ns), 'end_ns': str(end_ns)}
    reason = None
    if charging != 'unplugged': reason = 'charging_state_not_unplugged'
    if end_reason not in {'Time limit reached', 'User pressed Stop'}:
        reason = 'unexpected_trace_end'
    if not rows: reason = 'empty_power_table'
    cursor, coverage, gaps, overlaps = start_ns, 0, 0, 0
    max_gap = 0
    area = Decimal(0)
    previous_start = -1
    for row in rows:
        if row.start_ns <= previous_start or row.duration_ns <= 0 or not row.rate.is_finite() or row.rate < 0:
            reason = 'invalid_or_duplicate_power_interval'
            break
        previous_start = row.start_ns
        left, right = max(start_ns, row.start_ns), min(end_ns, row.start_ns + row.duration_ns)
        if left >= right: continue
        gap = max(0, left - cursor)
        overlap = max(0, min(cursor, right) - left)
        gaps += gap
        overlaps += overlap
        max_gap = max(max_gap, gap, overlap)
        if gap > boundary_tolerance_ns or overlap > boundary_tolerance_ns:
            reason = 'power_coverage_gap_or_overlap'
        # Tiny representational overlaps belong to the earlier interval only.
        length = max(0, right - max(cursor, left))
        area += row.rate * length
        coverage += length
        cursor = max(cursor, right)
    tail = max(0, end_ns - cursor)
    gaps += tail
    max_gap = max(max_gap, tail)
    if tail > boundary_tolerance_ns or (gaps + overlaps) * 100_000 > end_ns - start_ns:
        reason = 'incomplete_power_coverage'
    if coverage == 0: reason = reason or 'empty_power_window'
    mean = float(area / coverage) if coverage else None
    consumption = float(area / Decimal(3_600_000_000_000))
    return dict(mean=metric(mean, '%/hr', 'xctrace:SystemPowerLevel', interval, reason),
                consumption=metric(consumption, '% of total battery energy',
                                   'xctrace:SystemPowerLevel', interval, reason),
                coverage_ns=coverage, gap_ns=gaps, overlap_ns=overlaps,
                max_boundary_error_ns=max_gap, samples=len(rows), end_reason=end_reason,
                boundary_tolerance_ns=boundary_tolerance_ns)
