package com.byeolmuri.petai.platform;

import java.time.ZoneId;

final class CalendarEventDraft {
    final String requestID, title, location, timeZone;
    final long startMillis, endMillis;
    CalendarEventDraft(String requestID, String title, long startMillis, long endMillis, String location, String timeZone) {
        if (requestID == null || requestID.trim().isEmpty() || requestID.length() > 128 || endMillis <= startMillis)
            throw new CalendarFailure("invalid_arguments");
        this.requestID = requestID;
        this.title = text(title, 120, true);
        this.location = text(location, 200, false);
        try { this.timeZone = ZoneId.of(timeZone).getId(); }
        catch (RuntimeException failure) { throw new CalendarFailure("invalid_arguments"); }
        this.startMillis = startMillis; this.endMillis = endMillis;
    }
    private static String text(String value, int maximum, boolean required) {
        String normalized = value == null ? "" : value.trim();
        if ((required && normalized.isEmpty()) || normalized.codePointCount(0, normalized.length()) > maximum)
            throw new CalendarFailure("invalid_arguments");
        return normalized;
    }
    boolean matches(CalendarEngine.Event event, long calendarID) {
        return event.calendarID == calendarID && event.title.equals(title) && event.location.equals(location)
            && event.startMillis == startMillis && event.endMillis == endMillis && !event.allDay;
    }
}
