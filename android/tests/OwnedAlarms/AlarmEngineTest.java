package com.byeolmuri.petai.platform;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;

public final class AlarmEngineTest {
    static int checks;
    static void check(boolean condition, String message) {
        checks++;
        if (!condition) throw new AssertionError(message);
    }
    static final class Clock implements AlarmEngine.Clock {
        long wall = 1_800_000_000_000L, elapsed = 100_000;
        int boot = 4;
        public long wallMillis() { return wall; }
        public long elapsedMillis() { return elapsed; }
        public int bootCount() { return boot; }
    }
    static final class Store implements AlarmEngine.Store {
        final Map<String, AlarmRecord> rows = new LinkedHashMap<>();
        public AlarmRecord find(String id) { return rows.get(id); }
        public List<AlarmRecord> active() {
            List<AlarmRecord> result = new ArrayList<>();
            for (AlarmRecord row : rows.values()) if (row.active()) result.add(row);
            return result;
        }
        public void insert(AlarmRecord row, String label) { rows.put(row.id, row); }
        public boolean replace(AlarmRecord row, AlarmRecord.State expected) {
            if (rows.get(row.id).state != expected) return false;
            rows.put(row.id, row);
            return true;
        }
    }
    static final class Scheduler implements AlarmEngine.Scheduler {
        boolean allowed = true, fail;
        int calls, cancels;
        AlarmRecord last;
        public boolean permitted() { return allowed; }
        public void schedule(AlarmRecord row) throws AlarmFailure {
            if (fail) throw new AlarmFailure("native_failure");
            calls++; last = row;
        }
        public void cancel(AlarmRecord row) { cancels++; }
    }
    static final class Fixture {
        final Store store = new Store();
        final Scheduler scheduler = new Scheduler();
        final Clock clock = new Clock();
        AlarmEngine engine = new AlarmEngine(store, scheduler, clock);
        AlarmCommand alarm(String request) { return AlarmCommand.alarm(request, clock.wall + 60_000, "검증 알람"); }
    }
    static void expect(String code, Action action) throws Exception {
        try { action.run(); throw new AssertionError("Expected " + code); }
        catch (AlarmFailure error) { check(error.code.equals(code), "error code: " + error.code); }
    }
    interface Action { void run() throws Exception; }

    public static void main(String[] args) throws Exception {
        Fixture f = new Fixture();
        AlarmCommand command = f.alarm("request-1");
        AlarmRecord first = f.engine.create(command);
        f.engine = new AlarmEngine(f.store, f.scheduler, f.clock);
        check(f.engine.create(command).id.equals(first.id), "durable idempotency");
        check(f.scheduler.calls == 1, "retry must not reschedule a committed request");
        expect("invalid_arguments", () -> f.engine.create(AlarmCommand.alarm("request-1", command.wallMillis, "다른 이름")));
        f.scheduler.allowed = false;
        expect("permission_denied", () -> f.engine.create(command));
        f.scheduler.allowed = true; f.engine.reconcile(false);
        check(!f.engine.claim(first.id), "early broadcast must not ring");
        f.clock.wall += 60_000; f.clock.elapsed += 60_000;
        check(f.engine.claim(first.id), "due broadcast claims reservation");
        check(!f.engine.claim(first.id), "duplicate delivery is ignored");
        f.engine.stop(first.id);
        check(!f.engine.claim(first.id), "stopped delivery cannot reactivate");
        check(f.store.find(first.id).state == AlarmRecord.State.FINISHED, "stop is durable");

        Fixture denied = new Fixture(); denied.scheduler.allowed = false;
        expect("permission_denied", () -> denied.engine.create(denied.alarm("denied")));
        check(denied.store.rows.isEmpty(), "denied creation has no deferred side effect");
        Fixture failed = new Fixture(); failed.scheduler.fail = true;
        expect("native_failure", () -> failed.engine.create(failed.alarm("failed")));
        check(failed.store.active().isEmpty(), "failed registration does not appear active");
        failed.scheduler.fail = false; failed.engine.reconcile(false);
        check(failed.scheduler.calls == 0, "failed requests do not silently schedule later");

        Fixture recovery = new Fixture();
        AlarmCommand pending = recovery.alarm("crash");
        AlarmRecord staged = AlarmRecord.prepare(pending, recovery.clock);
        recovery.store.insert(staged, pending.label);
        recovery.engine.reconcile(false);
        check(recovery.store.find(staged.id).state == AlarmRecord.State.SCHEDULED, "recover interrupted registration");
        check(recovery.scheduler.last.id.equals(staged.id), "recovery replaces the same OS identity");
        recovery.scheduler.allowed = false; recovery.engine.reconcile(false);
        check(recovery.store.find(staged.id).state == AlarmRecord.State.BLOCKED, "revocation is visible");
        recovery.scheduler.allowed = true; recovery.engine.reconcile(false);
        check(recovery.store.find(staged.id).state == AlarmRecord.State.SCHEDULED, "regrant restores accepted reservation");

        Fixture timer = new Fixture();
        AlarmRecord timed = timer.engine.create(AlarmCommand.timer("timer", 30, "차"));
        timer.clock.wall += 3_600_000;
        check(!timer.engine.claim(timed.id), "clock jump cannot finish a same-boot timer");
        timer.clock.elapsed += 30_000;
        check(timer.engine.claim(timed.id), "elapsed deadline controls timer delivery");
        timer.engine.stop(timed.id);

        Fixture reboot = new Fixture();
        AlarmRecord rebootTimer = reboot.engine.create(AlarmCommand.timer("reboot", 120, "타이머"));
        reboot.clock.wall += 30_000; reboot.clock.elapsed = 5_000; reboot.clock.boot++;
        reboot.engine.reconcile(true);
        check(reboot.scheduler.last.elapsedDeadline == 95_000, "reboot retains remaining wall-clock duration");
        check(reboot.scheduler.last.bootCount == reboot.clock.boot, "timer boot epoch is rebased");
        reboot.clock.wall += 120_000; reboot.clock.boot++;
        reboot.engine.reconcile(true);
        check(reboot.store.find(rebootTimer.id).state == AlarmRecord.State.MISSED, "expired reboot backlog does not ring");

        Fixture stopped = new Fixture();
        AlarmRecord cancelled = stopped.engine.create(stopped.alarm("cancel"));
        stopped.engine.stop(cancelled.id);
        stopped.clock.wall += 60_000; stopped.clock.elapsed += 60_000;
        check(!stopped.engine.claim(cancelled.id), "queued delivery after cancellation is ignored");
        check(stopped.engine.create(stopped.alarm("another-request")).id.equals(cancelled.id) == false,
            "different requests retain distinct identities");

        Fixture concurrent = new Fixture();
        AlarmCommand same = concurrent.alarm("concurrent");
        CountDownLatch start = new CountDownLatch(1);
        List<Throwable> failures = java.util.Collections.synchronizedList(new ArrayList<>());
        List<Thread> workers = new ArrayList<>();
        for (int i = 0; i < 8; i++) {
            Thread worker = new Thread(() -> {
                try { start.await(); concurrent.engine.create(same); }
                catch (Throwable error) { failures.add(error); }
            });
            worker.start(); workers.add(worker);
        }
        start.countDown(); for (Thread worker : workers) worker.join();
        check(failures.isEmpty(), "concurrent callers succeeded");
        check(concurrent.scheduler.calls == 1 && concurrent.store.rows.size() == 1, "concurrent idempotency");

        Fixture malformed = new Fixture();
        expect("invalid_arguments", () -> malformed.engine.create(AlarmCommand.timer("empty", 10, "  ")));
        expect("unsupported_range", () -> malformed.engine.create(AlarmCommand.timer("range", 86_401, "타이머")));
        expect("past_schedule", () -> malformed.engine.create(AlarmCommand.alarm("past", malformed.clock.wall - 1, "지난 알람")));
        check(malformed.store.rows.isEmpty(), "invalid input cannot write or schedule");
        Fixture multiple = new Fixture();
        AlarmRecord one = multiple.engine.create(multiple.alarm("one"));
        AlarmRecord two = multiple.engine.create(multiple.alarm("two"));
        check(!one.id.equals(two.id) && multiple.scheduler.calls == 2, "same-time independent reservations stay distinct");
        multiple.clock.wall += 60_000; multiple.clock.elapsed += 60_000;
        check(multiple.engine.claim(one.id), "first independent alarm rings");
        multiple.engine.interruptPreviousRinging();
        check(multiple.store.find(one.id).state == AlarmRecord.State.MISSED, "process-death recovery reports interrupted ringing");
        System.out.println("Owned-alarm state checks passed (" + checks + ").");
    }
}
