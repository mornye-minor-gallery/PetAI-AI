package com.byeolmuri.petai.platform;

import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;

public final class CalendarEngineTest {
    private static int checks;
    private static void check(boolean value, String reason) {
        checks++; if (!value) throw new AssertionError(reason);
    }
    private interface Action { void run(); }
    private static void expect(String code, Action action) {
        try { action.run(); throw new AssertionError("Expected " + code); }
        catch (CalendarFailure failure) { check(failure.code.equals(code), "Wrong failure code"); }
    }
    private static final class Store implements CalendarEngine.Store {
        boolean read = true, write = true, writable = true, failInsert;
        int writes, reads;
        CalendarEngine.Event saved;
        final List<CalendarEngine.Event> events = new ArrayList<>();
        public boolean permitted(boolean writing) { return read && (!writing || write); }
        public boolean writable(long id) { return writable && id == 4; }
        public CalendarEngine.Event findOwned(String requestID) { return saved; }
        public CalendarEngine.Event insert(CalendarEventDraft draft, long calendarID) {
            writes++;
            if (failInsert) throw new CalendarFailure("native_failure");
            saved = new CalendarEngine.Event("27", calendarID, draft.title, draft.startMillis,
                draft.endMillis, draft.location, false);
            return saved;
        }
        public List<CalendarEngine.Event> query(CalendarQuery query) { reads++; return events; }
    }
    private static CalendarEventDraft draft(String id) {
        return new CalendarEventDraft(id, "검증 일정", 1_800_000_000_000L, 1_800_003_600_000L, "", "Asia/Seoul");
    }
    public static void main(String[] arguments) {
        Store source = new Store(); CalendarEngine engine = new CalendarEngine(source);
        CalendarEngine.Event event = engine.create(draft("one"), 4);
        check(event.id.equals("27") && source.writes == 1, "Successful insert returns the provider identity");
        engine = new CalendarEngine(source);
        check(engine.create(draft("one"), 4).id.equals("27") && source.writes == 1, "Retry after process restart does not duplicate");
        source.read = false;
        CalendarEngine denied = engine;
        expect("permission_denied", () -> denied.create(draft("one"), 4));
        check(source.writes == 1, "Read permission revocation does not write");
        source.read = true; source.write = false;
        expect("permission_denied", () -> denied.create(draft("one"), 4));
        source.write = true; source.saved = null; source.writable = false;
        expect("data_unavailable", () -> denied.create(draft("two"), 4));
        check(source.writes == 1, "Missing writable calendar does not cause a fallback insert");
        source.writable = true; source.failInsert = true;
        expect("native_failure", () -> denied.create(draft("two"), 4));
        source.failInsert = false;

        expect("invalid_arguments", () -> new CalendarEventDraft("", "title", 1, 2, null, "UTC"));
        expect("invalid_arguments", () -> new CalendarEventDraft("id", "  ", 1, 2, null, "UTC"));
        expect("invalid_arguments", () -> new CalendarEventDraft("id", "title", 2, 2, null, "UTC"));
        expect("invalid_arguments", () -> new CalendarEventDraft("id", "title", 2, 1, null, "UTC"));
        expect("invalid_arguments", () -> new CalendarEventDraft("id", "title", 1, 2, null, "not/a/zone"));
        expect("invalid_arguments", () -> new CalendarQuery(2, 1, "UTC", 10));
        expect("unsupported_range", () -> new CalendarQuery(0, 32L * 86_400_000L, "UTC", 10));
        expect("invalid_arguments", () -> new CalendarQuery(0, 86_400_000L, "UTC", 11));

        ZoneId zone = ZoneId.of("America/New_York");
        long start = LocalDate.parse("2026-03-08").atStartOfDay(zone).toInstant().toEpochMilli();
        long end = LocalDate.parse("2026-03-09").atStartOfDay(zone).toInstant().toEpochMilli();
        CalendarQuery query = new CalendarQuery(start, end, zone.getId(), 10);
        check(query.endMillis - query.startMillis == 23L * 3_600_000L, "DST query retains validated instants");
        CalendarEngine.Event allDay = CalendarEngine.Event.fromProvider("a", 4, "종일",
            Instant.parse("2026-03-08T00:00:00Z").toEpochMilli(),
            Instant.parse("2026-03-09T00:00:00Z").toEpochMilli(), null, true, zone);
        check(allDay.startMillis == start && allDay.endMillis == end, "All-day dates are interpreted in the query zone");
        check(query.overlaps(allDay), "All-day event appears on the requested local day");
        CalendarEngine.Event nextDay = CalendarEngine.Event.fromProvider("b", 4, "내일",
            Instant.parse("2026-03-09T00:00:00Z").toEpochMilli(),
            Instant.parse("2026-03-10T00:00:00Z").toEpochMilli(), null, true, zone);
        check(!query.overlaps(nextDay), "Exclusive boundary excludes the next local day");
        source.events.add(allDay); source.events.add(nextDay);
        check(engine.query(query).size() == 1, "Query returns only overlapping occurrences");
        source.write = false;
        check(engine.query(query).size() == 1, "Read-only grants suffice to query");
        source.read = false;
        expect("permission_denied", () -> denied.query(query));
        check(source.reads == 2, "Denied query never reads the provider");
        source.read = true; source.events.clear();
        check(engine.query(query).isEmpty(), "No appointments is a valid empty result");
        for (int i = 15; i >= 0; i--)
            source.events.add(new CalendarEngine.Event("e" + i, 4, "일정", start + i * 60_000,
                start + (i + 1) * 60_000, null, false));
        List<CalendarEngine.Event> ordered = engine.query(query);
        check(ordered.size() == 10 && ordered.get(0).id.equals("e0"), "Chronological results are capped at ten");
        System.out.println("PASS CalendarEngine " + checks + " checks");
    }
}
