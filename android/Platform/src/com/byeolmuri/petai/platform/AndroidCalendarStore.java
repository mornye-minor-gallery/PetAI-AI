package com.byeolmuri.petai.platform;

import android.Manifest;
import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.provider.CalendarContract;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.PriorityQueue;

final class AndroidCalendarStore implements CalendarEngine.Store {
    static final class Choice {
        final long id;
        final String label;
        Choice(long id, String label) { this.id = id; this.label = label; }
        @Override public String toString() { return label; }
    }
    private static final String[] EVENT_COLUMNS = {CalendarContract.Events._ID, CalendarContract.Events.CALENDAR_ID,
        CalendarContract.Events.TITLE, CalendarContract.Events.DTSTART, CalendarContract.Events.DTEND,
        CalendarContract.Events.EVENT_LOCATION, CalendarContract.Events.ALL_DAY};
    private final Context context;
    private final ContentResolver resolver;
    private final CancellationSignal cancellation;
    AndroidCalendarStore(Context context, CancellationSignal cancellation) {
        this.context = context.getApplicationContext(); resolver = this.context.getContentResolver();
        this.cancellation = cancellation;
    }
    public boolean permitted(boolean writing) {
        return context.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED
            && (!writing || context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED);
    }
    List<Choice> choices() {
        if (!permitted(false)) throw new CalendarFailure("permission_denied");
        List<Choice> choices = new ArrayList<>();
        String[] projection = {CalendarContract.Calendars._ID, CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.Calendars.ACCOUNT_NAME};
        String selection = CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL + ">=? AND "
            + CalendarContract.Calendars.VISIBLE + "=1 AND " + CalendarContract.Calendars.SYNC_EVENTS + "=1";
        try (Cursor cursor = resolver.query(CalendarContract.Calendars.CONTENT_URI, projection, selection,
                new String[]{String.valueOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR)},
                CalendarContract.Calendars._ID + " ASC", cancellation)) {
            if (cursor == null) throw new CalendarFailure("data_unavailable");
            while (cursor.moveToNext()) {
                String name = cursor.getString(1);
                if (name == null || name.trim().isEmpty()) name = "캘린더";
                String account = cursor.getString(3);
                boolean local = CalendarContract.ACCOUNT_TYPE_LOCAL.equals(cursor.getString(2));
                choices.add(new Choice(cursor.getLong(0), name + (local ? " (휴대폰)"
                    : account == null || account.trim().isEmpty() ? "" : " (" + account + ")")));
            }
        }
        return choices;
    }
    public boolean writable(long calendarID) {
        return choices().stream().anyMatch(choice -> choice.id == calendarID);
    }
    private String marker(String requestID) { return "petai-calendar:" + Uri.encode(requestID); }
    public CalendarEngine.Event findOwned(String requestID) {
        String where = CalendarContract.Events.CUSTOM_APP_PACKAGE + "=? AND "
            + CalendarContract.Events.CUSTOM_APP_URI + "=? AND " + CalendarContract.Events.DELETED + "=0";
        try (Cursor cursor = resolver.query(CalendarContract.Events.CONTENT_URI, EVENT_COLUMNS, where,
                new String[]{context.getPackageName(), marker(requestID)}, null, cancellation)) {
            if (cursor == null) throw new CalendarFailure("native_failure");
            if (!cursor.moveToFirst()) return null;
            CalendarEngine.Event event = event(cursor, false, ZoneId.of("UTC"));
            if (cursor.moveToNext()) throw new CalendarFailure("native_failure");
            return event;
        }
    }
    public CalendarEngine.Event insert(CalendarEventDraft draft, long calendarID) {
        ContentValues values = new ContentValues();
        values.put(CalendarContract.Events.CALENDAR_ID, calendarID);
        values.put(CalendarContract.Events.TITLE, draft.title);
        values.put(CalendarContract.Events.DTSTART, draft.startMillis);
        values.put(CalendarContract.Events.DTEND, draft.endMillis);
        values.put(CalendarContract.Events.EVENT_TIMEZONE, draft.timeZone);
        values.put(CalendarContract.Events.EVENT_LOCATION, draft.location);
        values.put(CalendarContract.Events.ALL_DAY, 0);
        // The request marker is committed in the same provider row as the event.
        // A retry after process death can find it without a second local DB or a
        // visible marker in the user's event title/description.
        values.put(CalendarContract.Events.CUSTOM_APP_PACKAGE, context.getPackageName());
        values.put(CalendarContract.Events.CUSTOM_APP_URI, marker(draft.requestID));
        Uri uri = resolver.insert(CalendarContract.Events.CONTENT_URI, values);
        if (uri == null) throw new CalendarFailure("native_failure");
        return new CalendarEngine.Event(String.valueOf(ContentUris.parseId(uri)), calendarID, draft.title,
            draft.startMillis, draft.endMillis, draft.location, false);
    }
    public List<CalendarEngine.Event> query(CalendarQuery query) {
        Uri.Builder uri = CalendarContract.Instances.CONTENT_URI.buildUpon();
        // Expand the native window because all-day instances use UTC dates. Only
        // locally overlapping occurrences survive below, including recurrent ones.
        ContentUris.appendId(uri, query.startMillis - 86_400_000L);
        ContentUris.appendId(uri, query.endMillis + 86_400_000L);
        String[] columns = {CalendarContract.Instances.EVENT_ID, CalendarContract.Events.CALENDAR_ID,
            CalendarContract.Events.TITLE, CalendarContract.Instances.BEGIN, CalendarContract.Instances.END,
            CalendarContract.Events.EVENT_LOCATION, CalendarContract.Events.ALL_DAY};
        String where = CalendarContract.Events.DELETED + "=0 AND (" + CalendarContract.Events.STATUS
            + " IS NULL OR " + CalendarContract.Events.STATUS + "!=?)";
        PriorityQueue<CalendarEngine.Event> nearest = new PriorityQueue<>(CalendarEngine.ORDER.reversed());
        try (Cursor cursor = resolver.query(uri.build(), columns, where,
                new String[]{String.valueOf(CalendarContract.Events.STATUS_CANCELED)}, null, cancellation)) {
            if (cursor == null) throw new CalendarFailure("native_failure");
            while (cursor.moveToNext()) {
                cancellation.throwIfCanceled();
                CalendarEngine.Event event = event(cursor, true, query.zone);
                if (!query.overlaps(event)) continue;
                nearest.add(event);
                if (nearest.size() > query.limit) nearest.poll();
            }
        }
        return new ArrayList<>(nearest);
    }
    private CalendarEngine.Event event(Cursor cursor, boolean occurrence, ZoneId zone) {
        long start = cursor.getLong(3), end = cursor.getLong(4);
        return occurrence ? CalendarEngine.Event.fromProvider(String.valueOf(cursor.getLong(0)), cursor.getLong(1), cursor.getString(2),
            start, end, cursor.getString(5), cursor.getInt(6) != 0, zone)
            : new CalendarEngine.Event(String.valueOf(cursor.getLong(0)), cursor.getLong(1), cursor.getString(2),
                start, end, cursor.getString(5), cursor.getInt(6) != 0);
    }
}
