package com.byeolmuri.petai.platform;

import android.content.Context;
import android.os.CancellationSignal;
import android.os.OperationCanceledException;
import android.util.Log;
import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Calendar I/O never shares the time-critical alarm executor or the UI thread. */
final class CalendarRuntime {
    static final ExecutorService WORK = Executors.newSingleThreadExecutor(r -> new Thread(r, "PetAI-calendar"));
    private static final ConcurrentHashMap<String, CancellationSignal> reads = new ConcurrentHashMap<>();
    static boolean supports(String tool) { return tool.equals("get_calendar_events") || tool.equals("create_calendar_event"); }
    static void submit(Context context, JSONObject request) {
        String id = request.optString("id");
        boolean reading = request.optString("tool").equals("get_calendar_events");
        CancellationSignal signal = new CancellationSignal();
        if (reading && reads.putIfAbsent(id, signal) != null) { PetAIPlatformBridge.reply(id, null, "native_failure"); return; }
        WORK.execute(() -> {
            try {
                if (context == null) throw new CalendarFailure("data_unavailable");
                signal.throwIfCanceled();
                JSONObject args = request.getJSONObject("arguments");
                String zone = args.getString("timeZoneIdentifier");
                CalendarEngine engine = new CalendarEngine(new AndroidCalendarStore(context, signal));
                JSONObject result;
                if (reading) {
                    CalendarQuery query = new CalendarQuery(args.getLong("startAtMillis"), args.getLong("endAtMillis"), zone, args.getInt("limit"));
                    JSONArray events = new JSONArray();
                    for (CalendarEngine.Event event : engine.query(query)) events.put(json(event, zone, false));
                    signal.throwIfCanceled();
                    result = new JSONObject().put("events", events);
                } else {
                    CalendarEventDraft draft = new CalendarEventDraft(request.getString("requestID"), args.getString("title"),
                        args.getLong("startAtMillis"), args.getLong("endAtMillis"), CalendarArguments.location(args), zone);
                    result = json(engine.create(draft, args.getLong("calendarID")), zone, true);
                }
                PetAIPlatformBridge.reply(id, result, null);
                Log.i("PetAI.Calendar", reading ? "query_completed" : "event_committed");
            } catch (Exception failure) {
                logFailure(failure); PetAIPlatformBridge.reply(id, null, errorCode(failure));
            } finally { if (reading) reads.remove(id, signal); }
        });
    }
    static void cancelRead(String id) {
        CancellationSignal signal = reads.get(id);
        if (signal != null) signal.cancel();
    }
    static JSONObject json(CalendarEngine.Event event, String timeZone, boolean created) throws JSONException {
        DateTimeFormatter format = DateTimeFormatter.ISO_OFFSET_DATE_TIME.withZone(ZoneId.of(timeZone));
        JSONObject result = new JSONObject().put("title", event.title)
            .put("startDateTime", format.format(Instant.ofEpochMilli(event.startMillis)))
            .put("endDateTime", format.format(Instant.ofEpochMilli(event.endMillis)));
        if (created) result.put("eventIdentifier", event.id);
        else result.put("isAllDay", event.allDay);
        return result;
    }
    static String errorCode(Throwable failure) {
        if (failure instanceof CalendarFailure) return ((CalendarFailure)failure).code;
        if (failure instanceof SecurityException) return "permission_denied";
        if (failure instanceof OperationCanceledException) return "cancelled_by_user";
        if (failure instanceof JSONException) return "invalid_arguments";
        return "native_failure";
    }
    static void logFailure(Throwable failure) {
        // No event titles, dates, locations or calendar/account labels in logs.
        Log.e("PetAI.Calendar", "operation_failed code=" + errorCode(failure) + " type=" + failure.getClass().getSimpleName());
    }
}
