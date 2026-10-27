package com.byeolmuri.petai.platform;

public final class AlarmRecord {
    public enum State { REGISTERING, SCHEDULED, RINGING, BLOCKED, FINISHED, MISSED, FAILED }
    public final String id, fingerprint, kind, errorCode;
    public final long wallMillis, elapsedDeadline;
    public final int bootCount, durationSeconds;
    public final State state;

    AlarmRecord(String id, String fingerprint, String kind, long wallMillis, long elapsedDeadline,
                int bootCount, int durationSeconds, State state, String errorCode) {
        this.id = id; this.fingerprint = fingerprint; this.kind = kind; this.wallMillis = wallMillis;
        this.elapsedDeadline = elapsedDeadline; this.bootCount = bootCount;
        this.durationSeconds = durationSeconds; this.state = state; this.errorCode = errorCode;
    }
    static AlarmRecord prepare(AlarmCommand command, AlarmEngine.Clock clock) {
        boolean timer = command.kind.equals("timer");
        long duration = command.durationSeconds * 1000L;
        return new AlarmRecord(command.id(), command.fingerprint(), command.kind,
            timer ? clock.wallMillis() + duration : command.wallMillis,
            timer ? clock.elapsedMillis() + duration : 0, clock.bootCount(), command.durationSeconds,
            State.REGISTERING, null);
    }
    AlarmRecord state(State next, String error) {
        return new AlarmRecord(id, fingerprint, kind, wallMillis, elapsedDeadline, bootCount, durationSeconds, next, error);
    }
    AlarmRecord timing(long wall, long elapsed, int boot) {
        return new AlarmRecord(id, fingerprint, kind, wall, elapsed, boot, durationSeconds, state, errorCode);
    }
    public boolean active() {
        return state == State.REGISTERING || state == State.SCHEDULED || state == State.RINGING || state == State.BLOCKED;
    }
    boolean due(AlarmEngine.Clock clock) {
        return kind.equals("timer") && bootCount == clock.bootCount()
            ? elapsedDeadline <= clock.elapsedMillis() : wallMillis <= clock.wallMillis();
    }
}
