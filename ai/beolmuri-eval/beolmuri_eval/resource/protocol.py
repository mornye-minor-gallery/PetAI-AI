"""Content-addressed commands are immutable, including across reconnects."""
import hashlib
import json
from pathlib import PurePosixPath
from .config import validate_document


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def command_bytes(command):
    validate_document('command', command)
    data = json.dumps(command, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':'), allow_nan=False).encode()
    return f"{command['operation_id']}.{sha256(data)}.json", data


def decode_command(name, data):
    if PurePosixPath(name).name != name: raise ValueError('unsafe command path')
    command = json.loads(data)
    expected, _ = command_bytes(command)
    # Validate the received bytes, not their reserialization (Swift/Python differ).
    expected = f"{command['operation_id']}.{sha256(data)}.json"
    if name != expected: raise ValueError('incomplete command or hash mismatch')
    return command
