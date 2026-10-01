"""A fresh file transfer can still contain an old device heartbeat."""
class Observation:
    def __init__(self, *, run_id, owner_id, stale_after=20):
        self.run_id, self.owner_id = run_id.lower(), owner_id.lower()
        self.stale_after = stale_after
        self.instance = None
        self.sequence = None
        self.advanced_at = None

    def observe(self, state, *, now):
        if state['run_id'].lower() != self.run_id or state['owner_id'].lower() != self.owner_id:
            raise ValueError('device state identity mismatch')
        if self.instance is not None and state['process_instance_id'] != self.instance:
            raise ValueError('device process changed; interrupted run cannot resume')
        self.instance = state['process_instance_id']
        seq = state['heartbeat_seq']
        if self.sequence is not None and seq < self.sequence: raise ValueError('heartbeat sequence regressed')
        if self.sequence is None or seq > self.sequence:
            self.sequence, self.advanced_at = seq, now
        terminal = state['phase'] in {'finished', 'failed', 'cancelled'}
        known = terminal or now - self.advanced_at <= self.stale_after
        return dict(observation='known' if known else 'unknown', last_device_state=state,
                    heartbeat_age_seconds=now-self.advanced_at)
