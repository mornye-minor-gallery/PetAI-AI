package com.byeolmuri.petai.platform;

import java.time.*;

public final class StepQueryTest {
    static int checks;
    static void check(boolean value) { checks++; if (!value) throw new AssertionError("check " + checks); }
    static void fails(String code, Runnable action) {
        try { action.run(); throw new AssertionError("expected " + code); }
        catch (StepFailure error) { check(error.code.equals(code)); }
    }
    public static void main(String[] args) {
        Instant now = Instant.parse("2026-10-15T12:00:00Z");
        Instant enabled = now.minusSeconds(3600);
        StepQuery firstDay = new StepQuery("2026-10-15", "2026-10-15", "total", "Asia/Seoul", now, enabled);
        check(firstDay.partial); check(firstDay.start.equals(enabled)); check(firstDay.end.equals(now));
        check(firstDay.windows.size() == 1);
        StepQuery allDay = new StepQuery("2026-10-15", "2026-10-15", "total", "Asia/Seoul", now, now.minusSeconds(86400));
        check(!allDay.partial); check(allDay.start.equals(Instant.parse("2026-10-14T15:00:00Z")));
        fails("data_unavailable", () -> new StepQuery("2026-10-14", "2026-10-14", "total", "Asia/Seoul", now, enabled));
        fails("unsupported_range", () -> new StepQuery("2026-10-16", "2026-10-16", "total", "Asia/Seoul", now, enabled));
        fails("invalid_arguments", () -> new StepQuery("2026-10-15", "2026-10-14", "daily", "Asia/Seoul", now, enabled));
        fails("invalid_arguments", () -> new StepQuery("bad", "2026-10-15", "total", "Asia/Seoul", now, enabled));
        fails("invalid_arguments", () -> new StepQuery("2026-10-15", "2026-10-15", "average", "Asia/Seoul", now, enabled));
        fails("data_unavailable", () -> new StepQuery("2026-10-15", "2026-10-15", "total", "Asia/Seoul", now, now.plusSeconds(1)));
        StepQuery retention = new StepQuery("2026-10-01", "2026-10-15", "daily", "Asia/Seoul", now, now.minusSeconds(86400 * 30));
        check(retention.partial); check(retention.start.equals(now.minus(Duration.ofDays(10))));
        check(retention.windows.size() == 11); // Ten rolling days can overlap eleven calendar dates.
        fails("data_unavailable", () -> new StepQuery("2026-10-01", "2026-10-02", "total", "Asia/Seoul", now, now.minusSeconds(86400 * 30)));
        StepQuery dst = new StepQuery("2026-03-08", "2026-03-08", "daily", "America/New_York",
            Instant.parse("2026-03-09T12:00:00Z"), Instant.parse("2026-03-07T00:00:00Z"));
        check(Duration.between(dst.start, dst.end).toHours() == 23);
        check(dst.windows.size() == 1); check(!dst.partial);
        StepQuery sameInstant = new StepQuery("2026-10-15", "2026-10-15", "total", "Asia/Seoul", now, now);
        check(sameInstant.windows.isEmpty()); // No invalid zero-length SDK read or fabricated count.
        System.out.println("StepQuery: " + checks + " checks passed");
    }
}
