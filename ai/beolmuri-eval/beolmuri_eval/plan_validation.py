"""Decode and validate engine settings in Swift before loading model weights."""
from pathlib import Path
import tempfile
from .config import repository
from .doctor import swift_binary
from .process import Worker


def validate_swift(plan):
    with tempfile.TemporaryDirectory(prefix='beolmuri-validate-') as temp:
        with Worker([str(swift_binary(repository()))], Path(temp)/'swift.log') as swift:
            for character in sorted({case['character_name'] for case in plan.cases}):
                swift.call('validate', configuration=plan.configuration, characterName=character)
