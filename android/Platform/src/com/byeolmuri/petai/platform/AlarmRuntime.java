package com.byeolmuri.petai.platform;

import android.content.Context;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.time.Instant;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** App-process owner, independent of Unity scenes and Swift/model lifetime. */
final class AlarmRuntime {
    static final ExecutorService WORK = Executors.newSingleThreadExecutor(r -> new Thread(r, "PetAI-alarms"));
    private static AlarmRuntime instance;
    final AlarmStore store;
    final AndroidAlarmScheduler scheduler;
    final AlarmEngine engine;

    static synchronized AlarmRuntime get(Context context) {
        if (instance == null) instance = new AlarmRuntime(context.getApplicationContext());
        return instance;
    }
    private AlarmRuntime(Context context) {
        store = new AlarmStore(context); scheduler = new AndroidAlarmScheduler(context);
        engine = new AlarmEngine(store, scheduler, new AlarmEngine.Clock() {
            public long wallMillis() { return System.currentTimeMillis(); }
            public long elapsedMillis() { return SystemClock.elapsedRealtime(); }
            public int bootCount() {
                try { return Settings.Global.getInt(context.getContentResolver(), Settings.Global.BOOT_COUNT); }
                catch (Settings.SettingNotFoundException error) { throw new IllegalStateException("Device boot epoch unavailable", error); }
            }
        });
        engine.interruptPreviousRinging();
    }
    JSONObject execute(JSONObject request) throws Exception {
        String tool = request.getString("tool");
        if (tool.equals("list_alarms")) return snapshot(false);
        JSONObject arguments = request.getJSONObject("arguments");
        String id = request.getString("requestID"), label = arguments.getString("label");
        AlarmCommand command;
        if (tool.equals("create_alarm")) command = AlarmCommand.alarm(id, arguments.getLong("scheduledAtMillis"), label);
        else if (tool.equals("create_timer")) command = AlarmCommand.timer(id, arguments.getInt("durationSeconds"), label);
        else throw new AlarmFailure("invalid_arguments");
        return json(engine.create(command));
    }
    JSONObject snapshot(boolean contextOnly) throws JSONException {
        JSONArray records = new JSONArray();
        for (AlarmRecord record : engine.active()) {
            if (contextOnly && (record.state == AlarmRecord.State.BLOCKED || record.state == AlarmRecord.State.REGISTERING)) continue;
            records.put(json(record));
        }
        return new JSONObject().put("alarms", records).put("authorized", scheduler.permitted());
    }
    JSONObject json(AlarmRecord record) throws JSONException {
        String state = record.state == AlarmRecord.State.RINGING ? "alerting"
            : record.state == AlarmRecord.State.SCHEDULED ? (record.kind.equals("timer") ? "countdown" : "scheduled")
            : record.state.name().toLowerCase(java.util.Locale.ROOT);
        JSONObject json = new JSONObject().put("id", record.id).put("kind", record.kind)
            .put("label", store.label(record)).put("state", state)
            .put("scheduledAt", Instant.ofEpochMilli(record.wallMillis).toString());
        if (record.durationSeconds > 0) json.put("durationSeconds", record.durationSeconds)
            .put("endsAt", Instant.ofEpochMilli(record.wallMillis).toString());
        if (record.errorCode != null) json.put("errorCode", record.errorCode);
        return json;
    }
    static void logFailure(String operation, Throwable error) {
        // No input text, labels, paths or account/provider payloads in operational logs.
        Log.e("PetAI.Alarms", operation + " failed type=" + error.getClass().getSimpleName()
            + (error instanceof AlarmFailure ? " code=" + ((AlarmFailure) error).code : ""));
    }
}
