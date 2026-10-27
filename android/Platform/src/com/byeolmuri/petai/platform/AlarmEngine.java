package com.byeolmuri.petai.platform;

import java.util.List;

/** App-owned reservation state. Android I/O stays behind the three small ports. */
public final class AlarmEngine {
    public interface Store {
        AlarmRecord find(String id);
        List<AlarmRecord> active();
        void insert(AlarmRecord record, String label);
        boolean replace(AlarmRecord record, AlarmRecord.State expected);
    }
    public interface Scheduler {
        boolean permitted();
        void schedule(AlarmRecord record) throws AlarmFailure;
        void cancel(AlarmRecord record) throws AlarmFailure;
    }
    public interface Clock {
        long wallMillis();
        long elapsedMillis();
        int bootCount();
    }

    // Bound OS resources and list payloads; the ledger itself is queried by primary key.
    public static final int MAX_ACTIVE = 50;
    private final Store store;
    private final Scheduler scheduler;
    private final Clock clock;

    public AlarmEngine(Store store, Scheduler scheduler, Clock clock) {
        this.store = store; this.scheduler = scheduler; this.clock = clock;
    }

    public synchronized AlarmRecord create(AlarmCommand command) throws AlarmFailure {
        command.validate();
        AlarmRecord existing = store.find(command.id());
        if (existing != null) {
            if (!existing.fingerprint.equals(command.fingerprint())) throw new AlarmFailure("invalid_arguments");
            if (existing.state == AlarmRecord.State.FAILED) throw new AlarmFailure(existing.errorCode);
            if (existing.active() && !scheduler.permitted()) {
                store.replace(existing.state(AlarmRecord.State.BLOCKED, "permission_denied"), existing.state);
                scheduler.cancel(existing);
                throw new AlarmFailure("permission_denied");
            }
            if (existing.state == AlarmRecord.State.REGISTERING) return register(existing);
            return existing;
        }
        if (!scheduler.permitted()) throw new AlarmFailure("permission_denied");
        if (command.kind.equals("alarm") && command.wallMillis <= clock.wallMillis()) throw new AlarmFailure("past_schedule");
        if (store.active().size() >= MAX_ACTIVE) throw new AlarmFailure("result_too_large");
        AlarmRecord record = AlarmRecord.prepare(command, clock);
        store.insert(record, command.label);
        return register(record);
    }

    private AlarmRecord register(AlarmRecord record) throws AlarmFailure {
        try {
            scheduler.schedule(record);
        } catch (AlarmFailure error) {
            // A reported failed creation must not be retried by background recovery.
            store.replace(record.state(AlarmRecord.State.FAILED, error.code), record.state);
            throw error;
        }
        try {
            store.replace(record.state(AlarmRecord.State.SCHEDULED, null), record.state);
            AlarmRecord result = store.find(record.id);
            // A separately delivered/finished reservation wins over scheduling completion.
            if (result == null) throw new IllegalStateException("Reservation disappeared");
            return result;
        } catch (RuntimeException error) {
            // OS and SQLite cannot commit atomically. Undo the OS side effect before failing.
            scheduler.cancel(record);
            store.replace(record.state(AlarmRecord.State.FAILED, "native_failure"), record.state);
            throw new AlarmFailure("native_failure", error);
        }
    }

    public synchronized boolean claim(String id) throws AlarmFailure {
        AlarmRecord record = store.find(id);
        if (record == null || (record.state != AlarmRecord.State.SCHEDULED
                && record.state != AlarmRecord.State.REGISTERING) || !record.due(clock)) return false;
        if (!scheduler.permitted()) {
            store.replace(record.state(AlarmRecord.State.BLOCKED, "permission_denied"), record.state);
            return false;
        }
        return store.replace(record.state(AlarmRecord.State.RINGING, null), record.state);
    }

    public synchronized void stop(String id) throws AlarmFailure {
        AlarmRecord record = store.find(id);
        if (record == null || !record.active()) return;
        // Tombstone first: a queued broadcast must never resurrect a stopped alarm.
        if (store.replace(record.state(AlarmRecord.State.FINISHED, null), record.state)) scheduler.cancel(record);
    }

    public synchronized void failDelivery(String id, String code) throws AlarmFailure {
        AlarmRecord record = store.find(id);
        if (record != null && record.active()
                && store.replace(record.state(AlarmRecord.State.FAILED, code), record.state)) scheduler.cancel(record);
    }

    public synchronized List<AlarmRecord> active() { return store.active(); }
    public synchronized AlarmRecord find(String id) { return store.find(id); }

    public synchronized void interruptPreviousRinging() {
        // A new process has no live audio owner. Never claim an old ringing state is playing.
        for (AlarmRecord record : store.active()) if (record.state == AlarmRecord.State.RINGING) {
            store.replace(record.state(AlarmRecord.State.MISSED, "process_interrupted"), record.state);
        }
    }

    public synchronized void reconcile(boolean reboot) throws AlarmFailure {
        AlarmFailure failure = null;
        for (AlarmRecord original : store.active()) {
            if (original.state == AlarmRecord.State.RINGING) continue;
            AlarmRecord record = original;
            boolean changedBoot = record.bootCount != clock.bootCount();
            if ((reboot || changedBoot) && record.wallMillis <= clock.wallMillis()) {
                store.replace(record.state(AlarmRecord.State.MISSED, "expired_during_reboot"), record.state);
                scheduler.cancel(record);
                continue;
            }
            if (!scheduler.permitted()) {
                store.replace(record.state(AlarmRecord.State.BLOCKED, "permission_denied"), record.state);
                scheduler.cancel(record);
                continue;
            }
            if (record.kind.equals("timer")) {
                long remaining = changedBoot ? record.wallMillis - clock.wallMillis()
                    : record.elapsedDeadline - clock.elapsedMillis();
                AlarmRecord timed = record.timing(clock.wallMillis() + remaining,
                    clock.elapsedMillis() + remaining, clock.bootCount());
                if (!store.replace(timed, record.state)) continue;
                record = timed;
            }
            try { register(record); }
            catch (AlarmFailure error) { failure = error; }
        }
        if (failure != null) throw failure;
    }
}
