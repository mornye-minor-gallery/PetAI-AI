package com.byeolmuri.petai.platform;

import android.content.Context;
import android.util.Log;
import com.google.android.gms.common.api.ApiException;
import java.time.Instant;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.*;

/** Read-only tool bridge. Recording starts only from the explicit native consent action. */
final class StepRuntime {
    static final ScheduledExecutorService WORK = Executors.newSingleThreadScheduledExecutor(r -> new Thread(r, "PetAI-steps"));
    private static LocalStepRecording recording;
    private static final ConcurrentHashMap<String, Read> reads = new ConcurrentHashMap<>();
    static synchronized LocalStepRecording get(Context context) {
        if (context == null) throw new StepFailure("data_unavailable");
        if (recording == null) recording = new LocalStepRecording(context);
        return recording;
    }
    private static final class Read {
        final AtomicBoolean done = new AtomicBoolean();
        volatile StepReader reader;
        volatile ScheduledFuture<?> heartbeat;
        void finish(String id, JSONObject data, String error) {
            if (!done.compareAndSet(false, true)) return;
            if (heartbeat != null) heartbeat.cancel(false);
            reads.remove(id, this); PetAIPlatformBridge.reply(id, data, error);
        }
        void cancel(String id) { if (reader != null) reader.cancel(); finish(id, null, "cancelled_by_user"); }
    }
    static void submit(Context context, JSONObject request) {
        String id = request.optString("id"); Read read = new Read();
        if (reads.putIfAbsent(id, read) != null) { PetAIPlatformBridge.reply(id, null, "native_failure"); return; }
        WORK.execute(() -> {
            if (read.done.get()) return;
            try {
                LocalStepRecording source = get(context);
                if (!source.permitted()) throw new StepFailure("permission_denied");
                JSONObject args = request.getJSONObject("arguments");
                StepQuery query = new StepQuery(args.getString("startDate"), args.getString("endDate"),
                    args.getString("aggregation"), args.getString("timeZoneIdentifier"), Instant.now(), source.recordedFrom());
                read.reader = new StepReader(source, query, WORK);
                read.heartbeat = WORK.scheduleAtFixedRate(() -> Log.i("PetAI.Steps", "query_pending"), 10, 10, TimeUnit.SECONDS);
                if (read.done.get()) { read.reader.cancel(); read.heartbeat.cancel(false); return; }
                read.reader.result.whenComplete((counts, error) -> {
                    try {
                        if (error != null) throw error;
                        read.finish(id, result(query, counts), null);
                        Log.i("PetAI.Steps", "query_completed");
                    } catch (Throwable failure) { log(failure); read.finish(id, null, code(failure)); }
                });
                read.reader.start();
            } catch (Exception error) { log(error); read.finish(id, null, code(error)); }
        });
    }
    static void cancelRead(String id) { Read read = reads.get(id); if (read != null) read.cancel(id); }
    static void cancelAllReads() { reads.forEach((id, read) -> read.cancel(id)); }
    private static JSONObject result(StepQuery query, List<Long> counts) throws JSONException {
        DateTimeFormatter format = DateTimeFormatter.ISO_OFFSET_DATE_TIME.withZone(query.zone);
        JSONObject result = new JSONObject().put("source", "google_local_recording")
            .put("startDate", query.firstDate.toString()).put("endDate", query.lastDate.toString())
            .put("aggregation", query.aggregation).put("partial", query.partial)
            .put("recordedFrom", format.format(query.start)).put("recordedUntil", format.format(query.end))
            .put("timeZoneIdentifier", query.zone.getId());
        if (query.aggregation.equals("total")) {
            long total = 0; for (long count : counts) total = Math.addExact(total, count);
            if (total > Integer.MAX_VALUE) throw new StepFailure("native_failure");
            result.put("totalSteps", total);
        } else {
            JSONArray days = new JSONArray();
            for (int i = 0; i < counts.size(); i++) days.put(new JSONObject()
                .put("date", query.windows.get(i).date.toString()).put("steps", counts.get(i)));
            result.put("days", days);
        }
        return result;
    }
    static String code(Throwable error) {
        while (error instanceof CompletionException && error.getCause() != null) error = error.getCause();
        if (error instanceof StepFailure) return ((StepFailure)error).code;
        if (error instanceof SecurityException) return "permission_denied";
        if (error instanceof JSONException) return "invalid_arguments";
        return "native_failure";
    }
    static void log(Throwable error) {
        // Record diagnostics, never step counts, dates, task messages or account data.
        Log.e("PetAI.Steps", "operation_failed code=" + code(error) + " type=" + error.getClass().getSimpleName()
            + (error instanceof ApiException ? " sdk=" + ((ApiException)error).getStatusCode() : ""));
    }
}
