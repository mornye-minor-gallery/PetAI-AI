package com.byeolmuri.petai.platform;

import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;

/** Calendar semantics shared by the Android host and its headless tests. */
final class CalendarEngine {
    interface Store {
        boolean permitted(boolean writing);
        boolean writable(long calendarID);
        Event findOwned(String requestID);
        Event insert(CalendarEventDraft draft, long calendarID);
        List<Event> query(CalendarQuery query);
    }
    static final Comparator<Event> ORDER = Comparator.comparingLong((Event event) -> event.startMillis)
        .thenComparingLong(event -> event.endMillis).thenComparing(event -> event.id);
    static final class Event {
        final String id, title, location;
        final long calendarID, startMillis, endMillis;
        final boolean allDay;
        Event(String id, long calendarID, String title, long startMillis, long endMillis, String location, boolean allDay) {
            this.id = id; this.calendarID = calendarID; this.title = title == null || title.trim().isEmpty() ? "제목 없음" : title;
            this.startMillis = startMillis; this.endMillis = endMillis;
            this.location = location == null ? "" : location; this.allDay = allDay;
        }
        static Event fromProvider(String id, long calendarID, String title, long start, long end,
                                   String location, boolean allDay, ZoneId zone) {
            if (allDay) {
                // Calendar Provider stores all-day boundaries in UTC; these are
                // calendar dates, not UTC instants to display on a different day.
                start = Instant.ofEpochMilli(start).atZone(ZoneOffset.UTC).toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli();
                end = Instant.ofEpochMilli(end).atZone(ZoneOffset.UTC).toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli();
            }
            return new Event(id, calendarID, title, start, end, location, allDay);
        }
    }
    private final Store store;
    CalendarEngine(Store store) { this.store = store; }
    synchronized Event create(CalendarEventDraft draft, long calendarID) {
        if (!store.permitted(true)) throw new CalendarFailure("permission_denied");
        Event existing = store.findOwned(draft.requestID);
        if (existing != null) {
            if (!draft.matches(existing, calendarID)) throw new CalendarFailure("invalid_arguments");
            return existing;
        }
        if (calendarID <= 0 || !store.writable(calendarID)) throw new CalendarFailure("data_unavailable");
        return store.insert(draft, calendarID);
    }
    List<Event> query(CalendarQuery query) {
        if (!store.permitted(false)) throw new CalendarFailure("permission_denied");
        return store.query(query).stream().filter(query::overlaps).sorted(ORDER).limit(query.limit).collect(Collectors.toList());
    }
}
