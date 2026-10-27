package com.byeolmuri.petai.platform;

final class NotificationRecord {
    enum State { REGISTERING, SCHEDULED, POSTING, DELIVERED, CANCELLED, EXPIRED, BLOCKED, FAILED }
    final String id, requestID, title, body, deepLink, error;
    final long at;
    final State state;
    NotificationRecord(String id, String requestID, String title, String body, long at, String deepLink, State state, String error) {
        this.id = id; this.requestID = requestID; this.title = title; this.body = body;
        this.at = at; this.deepLink = deepLink; this.state = state; this.error = error;
    }
    static NotificationRecord draft(String id, String requestID, String title, String body, long at, String deepLink) throws NotificationFailure {
        if (id == null || !id.matches("[a-zA-Z0-9_-]{1,128}") || requestID == null || requestID.isEmpty() || requestID.length() > 160
                || title == null || title.trim().isEmpty() || title.length() > 120
                || body == null || body.trim().isEmpty() || body.length() > 500 || at <= 0
                || !("petai://notification/" + id).equals(deepLink)) throw new NotificationFailure("invalid_arguments");
        return new NotificationRecord(id, requestID, title.trim(), body.trim(), at, deepLink, State.REGISTERING, null);
    }
    NotificationRecord state(State value, String error) { return new NotificationRecord(id, requestID, title, body, at, deepLink, value, error); }
    static long parseTime(String iso) throws NotificationFailure {
        try { return java.time.OffsetDateTime.parse(iso).toInstant().toEpochMilli(); }
        catch (RuntimeException error) { throw new NotificationFailure("invalid_arguments"); }
    }
    boolean sameContent(NotificationRecord other) {
        return id.equals(other.id) && title.equals(other.title) && body.equals(other.body) && at == other.at && deepLink.equals(other.deepLink);
    }
    boolean pending() { return state == State.REGISTERING || state == State.SCHEDULED || state == State.BLOCKED; }
}
