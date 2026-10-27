package com.byeolmuri.petai.platform;

import java.time.Instant;
import java.time.ZoneId;
import java.time.temporal.ChronoUnit;

final class CalendarQuery {
    final long startMillis, endMillis;
    final ZoneId zone;
    final int limit;
    CalendarQuery(long startMillis, long endMillis, String timeZone, int limit) {
        if (endMillis <= startMillis || limit < 1 || limit > 10) throw new CalendarFailure("invalid_arguments");
        try { zone = ZoneId.of(timeZone); }
        catch (RuntimeException failure) { throw new CalendarFailure("invalid_arguments"); }
        long days = ChronoUnit.DAYS.between(Instant.ofEpochMilli(startMillis).atZone(zone).toLocalDate(),
            Instant.ofEpochMilli(endMillis).atZone(zone).toLocalDate());
        if (days > 31) throw new CalendarFailure("unsupported_range");
        this.startMillis = startMillis; this.endMillis = endMillis; this.limit = limit;
    }
    boolean overlaps(CalendarEngine.Event event) { return event.startMillis < endMillis && event.endMillis > startMillis; }
}
