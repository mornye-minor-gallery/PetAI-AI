package com.byeolmuri.petai.platform;

import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.List;

/** Google retains ten rolling days. Never fill an unrecorded date with zero. */
final class StepQuery {
    final LocalDate firstDate, lastDate;
    final String aggregation;
    final ZoneId zone;
    final Instant start, end;
    final boolean partial;
    final List<Window> windows = new ArrayList<>();

    static final class Window {
        final LocalDate date;
        final Instant start, end;
        Window(LocalDate date, Instant start, Instant end) { this.date = date; this.start = start; this.end = end; }
    }
    StepQuery(String first, String last, String aggregation, String timeZone, Instant now, Instant recordedFrom) {
        try {
            firstDate = LocalDate.parse(first); lastDate = LocalDate.parse(last); zone = ZoneId.of(timeZone);
        } catch (DateTimeException | NullPointerException error) { throw new StepFailure("invalid_arguments"); }
        if (lastDate.isBefore(firstDate) || ChronoUnit.DAYS.between(firstDate, lastDate) > 30
                || !("total".equals(aggregation) || "daily".equals(aggregation))) throw new StepFailure("invalid_arguments");
        this.aggregation = aggregation;
        if (lastDate.isAfter(now.atZone(zone).toLocalDate())) throw new StepFailure("unsupported_range");
        if (recordedFrom == null || recordedFrom.isAfter(now)) throw new StepFailure("data_unavailable");
        Instant requestedStart = firstDate.atStartOfDay(zone).toInstant();
        Instant requestedEnd = lastDate.plusDays(1).atStartOfDay(zone).toInstant();
        Instant available = later(recordedFrom, now.minus(Duration.ofDays(10)));
        start = later(requestedStart, available); end = earlier(requestedEnd, now);
        if (start.isAfter(end) || !requestedEnd.isAfter(available)) throw new StepFailure("data_unavailable");
        partial = start.isAfter(requestedStart);
        for (LocalDate day = start.atZone(zone).toLocalDate(); !day.isAfter(lastDate); day = day.plusDays(1)) {
            Instant from = later(day.atStartOfDay(zone).toInstant(), start);
            Instant to = earlier(day.plusDays(1).atStartOfDay(zone).toInstant(), end);
            if (from.isBefore(to)) windows.add(new Window(day, from, to));
        }
    }
    private static Instant later(Instant a, Instant b) { return a.isAfter(b) ? a : b; }
    private static Instant earlier(Instant a, Instant b) { return a.isBefore(b) ? a : b; }
}
