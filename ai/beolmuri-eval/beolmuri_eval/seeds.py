"""Versioned, order-independent seeds; GPU bitwise reproducibility is not implied."""
import hashlib
import json

POLICY = 'sha256-sample-v1; world-info advances by completed messages in Swift'


def sample_seeds(base, group, repeat, turn):
    def derive(domain, *parts):
        payload = json.dumps([domain, base, group, repeat, *parts], ensure_ascii=False, separators=(',', ':'))
        return int.from_bytes(hashlib.sha256(payload.encode()).digest()[:4], 'big') & 0x7fffffff
    return {'generation': derive('generation', turn), 'world_info_base': derive('world-info')}
