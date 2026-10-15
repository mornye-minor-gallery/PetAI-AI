package com.byeolmuri.petai.platform;

import java.util.*;

public final class NotificationEngineTest {
    static int checks;
    static void check(boolean condition) { checks++; if (!condition) throw new AssertionError("check " + checks); }
    static final class Store implements NotificationEngine.Store {
        Map<String, NotificationRecord> rows = new LinkedHashMap<>(), requests = new HashMap<>();
        public NotificationRecord find(String id) { return rows.get(id); }
        public NotificationRecord request(String id) { return requests.get(id); }
        public List<NotificationRecord> all() { return new ArrayList<>(rows.values()); }
        public void save(NotificationRecord record, boolean receipt) {
            rows.put(record.id, record); if (receipt) requests.put(record.requestID, record);
        }
    }
    static final class Delivery implements NotificationEngine.Delivery {
        boolean allowed = true, fail; int schedules, posts, cancels;
        public boolean permitted() { return allowed; }
        public void schedule(NotificationRecord r) throws NotificationFailure {
            if (fail) throw new NotificationFailure("native_failure"); schedules++;
        }
        public void cancel(NotificationRecord r) { cancels++; }
        public void post(NotificationRecord r) { posts++; }
    }
    static long now = 1000;
    static NotificationRecord draft(String id, String request, long at) throws NotificationFailure {
        return NotificationRecord.draft(id, request, "택배", "택배를 보내요", at, "petai://notification/" + id);
    }
    interface Attempt { void run() throws Exception; }
    static void fails(String code, Attempt attempt) throws Exception {
        try { attempt.run(); throw new AssertionError("Expected " + code); }
        catch (NotificationFailure error) { check(error.code.equals(code)); }
    }
    public static void main(String[] args) throws Exception {
        Store store = new Store(); Delivery delivery = new Delivery();
        NotificationEngine engine = new NotificationEngine(store, delivery, () -> now);
        NotificationRecord a = draft("a", "r1", 2000);
        check(engine.schedule(a).state == NotificationRecord.State.SCHEDULED);
        engine.schedule(a); check(delivery.schedules == 1);
        fails("invalid_arguments", () -> engine.schedule(draft("a", "r1", 3000)));
        fails("past_schedule", () -> engine.schedule(draft("past", "past", 900)));
        delivery.allowed = false;
        fails("permission_denied", () -> engine.schedule(draft("b", "r2", 2000)));
        delivery.allowed = true;
        engine.cancel("a"); engine.cancel("a"); now = 2100;
        engine.deliver("a"); check(delivery.posts == 0);
        fails("cancelled_by_user", () -> engine.schedule(a));
        now = 1000; engine.schedule(draft("b", "r2", 2000));
        engine.schedule(draft("b", "r3", 3000));
        fails("request_superseded", () -> engine.schedule(draft("b", "r2", 2000)));
        now = 2100; engine.deliver("b"); check(delivery.posts == 0);
        now = 3100; engine.deliver("b"); engine.deliver("b"); check(delivery.posts == 1);
        now = 1000; engine.schedule(draft("c", "r4", 2000));
        now = 3000; engine.restore(); check(store.find("c").state == NotificationRecord.State.EXPIRED);
        fails("past_schedule", () -> engine.schedule(draft("c", "r4", 2000)));
        engine.deliver("c"); check(delivery.posts == 1);
        now = 1000; engine.schedule(draft("d", "r5", 2000));
        delivery.allowed = false; engine.restore(); check(store.find("d").state == NotificationRecord.State.BLOCKED);
        delivery.allowed = true; engine.restore(); check(store.find("d").state == NotificationRecord.State.SCHEDULED);
        delivery.fail = true;
        fails("native_failure", () -> engine.schedule(draft("e", "r6", 2000)));
        check(store.find("e").state == NotificationRecord.State.FAILED);
        delivery.fail = false; engine.restore(); check(store.find("e").state == NotificationRecord.State.FAILED);
        fails("invalid_arguments", () -> NotificationRecord.draft("../bad", "r", "x", "y", 2000, "https://bad"));
        engine.cancelAll(); check(engine.pending().isEmpty());
        // Pending registration is recoverable, failed creation is not silently retried.
        store.save(draft("interrupted", "r7", 4000), true);
        engine.restore(); check(store.find("interrupted").state == NotificationRecord.State.SCHEDULED);
        store.save(draft("uncertain", "r8", 4000).state(NotificationRecord.State.POSTING, null), true);
        engine.restore(); check(store.find("uncertain").error.equals("delivery_unconfirmed"));
        // Permission revocation must be checked at delivery, not just at scheduling.
        delivery.allowed = false; now = 4001; engine.deliver("interrupted");
        check(store.find("interrupted").state == NotificationRecord.State.BLOCKED);
        check(delivery.posts == 1);
        delivery.allowed = true; engine.restore(); check(store.find("interrupted").state == NotificationRecord.State.EXPIRED);
        now = 1000; engine.cancelAll();
        for (int i = 0; i < 50; i++) engine.schedule(draft("limit" + i, "limit" + i, 5000));
        fails("result_too_large", () -> engine.schedule(draft("over", "over", 5000)));
        engine.cancelAll();
        fails("invalid_arguments", () -> NotificationRecord.draft("ok", "r", "", "body", 5000, "petai://notification/ok"));
        fails("invalid_arguments", () -> NotificationRecord.draft("ok", "r", "title", "body", 5000, "https://example.org"));
        engine.schedule(draft("race", "race", 2000)); now = 2100;
        java.util.concurrent.atomic.AtomicReference<Throwable> raceError = new java.util.concurrent.atomic.AtomicReference<>();
        Thread cancel = new Thread(() -> { try { engine.cancel("race"); } catch (Throwable e) { raceError.set(e); } });
        Thread deliver = new Thread(() -> { try { engine.deliver("race"); } catch (Throwable e) { raceError.set(e); } });
        cancel.start(); deliver.start(); cancel.join(); deliver.join();
        check(raceError.get() == null); check(store.find("race").state == NotificationRecord.State.CANCELLED);
        int posted = delivery.posts; engine.deliver("race"); check(delivery.posts == posted);
        fails("invalid_arguments", () -> engine.cancel(null));
        check(NotificationRecord.parseTime("2026-10-20T15:00:00.0000000+09:00") == NotificationRecord.parseTime("2026-10-20T06:00:00Z"));
        fails("invalid_arguments", () -> NotificationRecord.parseTime("2026-10-20T15:00"));
        System.out.println("NotificationEngine: " + checks + " checks passed");
    }
}
