"""Copy into unique staging files; only hash-verified immutable files become raw evidence."""
from pathlib import Path, PurePosixPath
import os
from uuid import uuid4
from .protocol import sha256


def safe_relative(value):
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(p in {'.', '..'} for p in value.split('/')):
        raise ValueError('unsafe artifact path')
    if path.parts[0] != 'raw' or '\\' in value: raise ValueError('artifact must be under raw/')
    return path


def collect_files(root, index, fetch):
    root = Path(root)
    staging = root / 'transfers'
    staging.mkdir(parents=True, exist_ok=True)
    seen = set()
    for entry in index['files']:
        relative = safe_relative(entry['path'])
        if str(relative) in seen: raise ValueError('duplicate artifact entry')
        seen.add(str(relative))
        destination = root / str(relative)
        for parent in (destination, *destination.parents):
            if parent == root.parent: break
            if parent.is_symlink(): raise ValueError('symlink in artifact destination')
        def verify(path):
            data = path.read_bytes()
            return len(data) == entry['bytes'] and sha256(data) == entry['sha256']
        if destination.exists():
            if not verify(destination): raise ValueError('existing raw artifact conflicts with manifest')
            continue
        pending = staging / (str(uuid4()) + '.partial')
        fetch(str(relative), pending)
        if not verify(pending): raise ValueError('artifact hash or size mismatch; partial file preserved')
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Link is an exclusive publish: another collector cannot overwrite this path.
        with pending.open('rb') as handle: os.fsync(handle.fileno())
        os.link(pending, destination)
        descriptor = os.open(destination.parent, os.O_RDONLY)
        try: os.fsync(descriptor)
        finally: os.close(descriptor)
    return index
