"""Validate recorded state chains before resuming any generation."""
from .comparison import checked_records
from .config import digest
from .scenarios import execution_groups


def validate_chains(directory, manifest):
    rows = checked_records(directory, manifest)
    for repeat in range(manifest['repeats']):
        for _, cases in execution_groups(manifest['cases']):
            previous = None
            gap = False
            for case in cases:
                row = rows.get(f"{case['id']}-r{repeat}")
                if row is None or 'generation' not in row:
                    if row and row['status'] in ('graded', 'completed'):
                        raise ValueError('completed record lacks generation')
                    gap = True
                    continue
                if gap:
                    raise ValueError('session checkpoint chain has a missing predecessor')
                if row.get('session_before_sha256') != digest(previous):
                    raise ValueError('session checkpoint chain changed')
                previous = row.get('session_after')
                if not isinstance(previous, dict) or digest(previous) != row.get('session_after_sha256'):
                    raise ValueError('session checkpoint changed')
