package com.byeolmuri.petai.platform;

import android.content.Context;
import android.util.Log;
import java.time.Instant;
import java.util.concurrent.*;
import org.json.*;

/** Shared by the Swift tool, Unity management and OS receivers; never loads the model. */
final class NotificationRuntime {
    static final ExecutorService WORK = Executors.newSingleThreadExecutor(r -> new Thread(r, "PetAI-notifications"));
    static final ConcurrentLinkedQueue<String> EVENTS = new ConcurrentLinkedQueue<>();
    private static NotificationRuntime instance;
    final NotificationStore store;
    final AndroidNotificationScheduler scheduler;
    final NotificationEngine engine;
    static synchronized NotificationRuntime get(Context context) {
        if (instance == null) instance = new NotificationRuntime(context.getApplicationContext());
        return instance;
    }
    private NotificationRuntime(Context context) {
        store = new NotificationStore(context); scheduler = new AndroidNotificationScheduler(context);
        engine = new NotificationEngine(store, scheduler, System::currentTimeMillis);
    }
    JSONObject schedule(JSONObject value) throws Exception {
        NotificationRecord draft = NotificationRecord.draft(value.getString("notificationId"), value.getString("requestId"),
            value.getString("title"), value.getString("body"), NotificationRecord.parseTime(value.getString("scheduledAtIso")), value.getString("deepLink"));
        try {
            NotificationRecord result = engine.schedule(draft);
            EVENTS.add(json(result).put("type", "notification_result").put("operation", "schedule").put("success", true).toString());
            return new JSONObject().put("notificationId", result.id).put("scheduledAt", Instant.ofEpochMilli(result.at).toString());
        } catch (NotificationFailure error) {
            EVENTS.add(json(draft).put("type", "notification_result").put("operation", "schedule").put("success", false)
                .put("failureCode", error.code).toString());
            throw error;
        }
    }
    JSONObject execute(JSONObject request) throws Exception {
        JSONObject args = request.getJSONObject("arguments");
        String id = "local-notification-" + request.getString("requestID");
        return schedule(new JSONObject().put("notificationId", id).put("requestId", request.getString("requestID"))
            .put("title", args.getString("title")).put("body", args.getString("body"))
            .put("scheduledAtIso", Instant.ofEpochMilli(args.getLong("scheduledAtMillis")).toString())
            .put("deepLink", "petai://notification/" + id));
    }
    JSONObject contextSnapshot() throws JSONException {
        JSONArray rows = new JSONArray();
        if (scheduler.permitted()) for (NotificationRecord record : engine.pending())
            if (record.state == NotificationRecord.State.SCHEDULED && record.at > System.currentTimeMillis()) rows.put(json(record));
        return new JSONObject().put("authorized", scheduler.permitted()).put("notifications", rows);
    }
    void snapshot() throws JSONException {
        JSONArray rows = new JSONArray();
        for (NotificationRecord record : engine.visible()) rows.put(json(record));
        EVENTS.add(new JSONObject().put("type", "notification_snapshot").put("notifications", rows).toString());
    }
    void permission(boolean requested) throws JSONException {
        EVENTS.add(new JSONObject().put("type", "permission_result").put("permission", "notifications")
            .put("permissionStatus", scheduler.permitted() ? "Authorized" : "Denied").put("requestSubmitted", requested).toString());
    }
    static JSONObject json(NotificationRecord record) throws JSONException {
        boolean failed = record.state == NotificationRecord.State.FAILED || record.state == NotificationRecord.State.BLOCKED;
        return new JSONObject().put("notificationId", record.id).put("requestId", record.requestID).put("title", record.title)
            .put("body", record.body).put("scheduledAtIso", Instant.ofEpochMilli(record.at).toString()).put("deepLink", record.deepLink)
            .put("status", failed ? "Failed" : "Scheduled").put("failureCode", record.error == null ? "" : record.error);
    }
    static void log(String operation, Throwable error) {
        Log.e("PetAI.Notifications", operation + " failed type=" + error.getClass().getSimpleName()
            + (error instanceof NotificationFailure ? " code=" + ((NotificationFailure) error).code : ""));
    }
}
