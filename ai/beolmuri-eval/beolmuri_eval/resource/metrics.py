"""Every unavailable value carries its reason, unit, interval, and source."""

def metric(value, unit, source, interval, reason=None, status='invalid'):
    return dict(status='ok' if reason is None else status,
                value=value if reason is None else None, unit=unit,
                source=source, interval=interval, reason=reason)
