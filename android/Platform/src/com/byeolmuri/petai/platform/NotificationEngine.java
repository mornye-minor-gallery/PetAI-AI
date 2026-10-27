package com.byeolmuri.petai.platform;

import java.util.ArrayList;
import java.util.List;

/** Single process owner serializes delivery and cancellation, including receiver work. */
final class NotificationEngine {
    interface Store {
        NotificationRecord find(String id);
        NotificationRecord request(String requestID);
        List<NotificationRecord> all();
        void save(NotificationRecord record, boolean receipt);
    }
    interface Delivery {
        boolean permitted();
        void schedule(NotificationRecord record) throws NotificationFailure;
        void cancel(NotificationRecord record) throws NotificationFailure;
        void post(NotificationRecord record) throws NotificationFailure;
    }
    interface Clock { long now(); }
    private final Store store;
    private final Delivery delivery;
    private final Clock clock;
    NotificationEngine(Store store, Delivery delivery, Clock clock) { this.store = store; this.delivery = delivery; this.clock = clock; }

    synchronized NotificationRecord schedule(NotificationRecord draft) throws NotificationFailure {
        NotificationRecord previous = store.find(draft.id), receipt = store.request(draft.requestID);
        if (receipt != null) {
            if (!receipt.sameContent(draft)) throw new NotificationFailure("invalid_arguments");
            if (previous == null || !previous.requestID.equals(draft.requestID)) throw new NotificationFailure("request_superseded");
            if (previous.state == NotificationRecord.State.CANCELLED) throw new NotificationFailure("cancelled_by_user");
            if (previous.state == NotificationRecord.State.EXPIRED) throw new NotificationFailure("past_schedule");
            if (previous.state == NotificationRecord.State.FAILED) throw new NotificationFailure(previous.error);
            if (!previous.pending()) return previous;
            if (!delivery.permitted()) throw new NotificationFailure("permission_denied");
            if (previous.state == NotificationRecord.State.SCHEDULED) return previous;
        }
        if (draft.at <= clock.now()) throw new NotificationFailure("past_schedule");
        if (!delivery.permitted()) throw new NotificationFailure("permission_denied");
        if ((previous == null || !previous.pending()) && pending().size() >= 50) throw new NotificationFailure("result_too_large");
        // Persist intent before touching AlarmManager. Recovery can finish an interrupted registration.
        store.save(draft, receipt == null);
        return register(draft);
    }
    private NotificationRecord register(NotificationRecord record) throws NotificationFailure {
        try {
            delivery.schedule(record);
            NotificationRecord ready = record.state(NotificationRecord.State.SCHEDULED, null);
            store.save(ready, false);
            return ready;
        } catch (NotificationFailure | RuntimeException error) {
            String code = error instanceof NotificationFailure ? ((NotificationFailure) error).code : "native_failure";
            // Even when persistence itself fails, still undo the OS side effect.
            try { store.save(record.state(NotificationRecord.State.FAILED, code), false); }
            finally { delivery.cancel(record); }
            throw new NotificationFailure(code);
        }
    }
    synchronized void cancel(String id) throws NotificationFailure {
        if (id == null || !id.matches("[a-zA-Z0-9_-]{1,128}")) throw new NotificationFailure("invalid_arguments");
        NotificationRecord record = store.find(id);
        if (record == null) return;
        // Tombstone before OS cancellation: a broadcast already queued cannot resurrect it.
        store.save(record.state(NotificationRecord.State.CANCELLED, null), false);
        delivery.cancel(record);
    }
    synchronized void cancelAll() throws NotificationFailure {
        for (NotificationRecord record : store.all()) cancel(record.id);
    }
    synchronized void deliver(String id) throws NotificationFailure {
        NotificationRecord record = store.find(id);
        if (record == null || !record.pending() || record.at > clock.now()) return;
        if (!delivery.permitted()) { store.save(record.state(NotificationRecord.State.BLOCKED, "permission_denied"), false); return; }
        store.save(record.state(NotificationRecord.State.POSTING, null), false);
        try {
            delivery.post(record);
            store.save(record.state(NotificationRecord.State.DELIVERED, null), false);
        } catch (NotificationFailure | RuntimeException error) {
            store.save(record.state(NotificationRecord.State.FAILED, "native_failure"), false);
            throw new NotificationFailure("native_failure");
        }
    }
    synchronized List<NotificationRecord> pending() {
        List<NotificationRecord> rows = new ArrayList<>();
        for (NotificationRecord record : store.all()) if (record.pending()) rows.add(record);
        return rows;
    }
    synchronized List<NotificationRecord> visible() {
        List<NotificationRecord> rows = new ArrayList<>();
        for (NotificationRecord record : store.all())
            if (record.pending() || record.state == NotificationRecord.State.FAILED || record.state == NotificationRecord.State.DELIVERED) rows.add(record);
        return rows;
    }
    synchronized void restore() throws NotificationFailure {
        NotificationFailure failure = null;
        for (NotificationRecord record : store.all()) {
            if (record.state == NotificationRecord.State.CANCELLED || record.state == NotificationRecord.State.EXPIRED) {
                delivery.cancel(record); continue;
            }
            // A crash between notify() and persistence cannot prove delivery. Do not alert twice.
            if (record.state == NotificationRecord.State.POSTING) {
                store.save(record.state(NotificationRecord.State.FAILED, "delivery_unconfirmed"), false); continue;
            }
            if (!record.pending()) continue;
            if (record.at <= clock.now()) {
                store.save(record.state(NotificationRecord.State.EXPIRED, "past_schedule"), false); delivery.cancel(record); continue;
            }
            if (!delivery.permitted()) {
                store.save(record.state(NotificationRecord.State.BLOCKED, "permission_denied"), false); delivery.cancel(record); continue;
            }
            try { register(record); } catch (NotificationFailure error) { failure = error; }
        }
        if (failure != null) throw failure;
    }
}
