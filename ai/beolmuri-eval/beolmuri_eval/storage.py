import contextlib
import fcntl
import json
import os
from pathlib import Path
import tempfile
import time


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".pending-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def records(directory):
    return [read_json(path) for path in sorted((Path(directory) / "records").glob("*.json"))]


def event(directory, kind, **details):
    # The authoritative checkpoint is an atomic record per turn. The event log
    # is diagnostic and may have an incomplete final line after a hard crash.
    with open(Path(directory) / "events.jsonl", "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"time": time.time(), "event": kind, **details}, ensure_ascii=False) + "\n")
        handle.flush()


@contextlib.contextmanager
def run_lock(directory):
    path = Path(directory) / ".lock"
    with path.open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("this run already has an active owner") from error
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def active(directory):
    with (Path(directory) / ".lock").open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
        return False
