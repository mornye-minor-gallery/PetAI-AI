package com.byeolmuri.petai.platform;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.json.JSONObject;

/** Separate debug APK, not a product source set. agentctl can drive the shared core. */
public final class PetAIAlarmAgent extends Activity {
    private static Context app;
    private static native void nativeSubmit(byte[] json);
    @Override public void onCreate(Bundle state) {
        super.onCreate(state); app = getApplicationContext();
        TextView status = new TextView(this); status.setText("별무리 알람 검사\nagentctl에서 명령과 결과를 확인합니다."); setContentView(status);
        PetAIPlatformBridge.install(this);
        PetAINotificationBridge.install(this);
        receive(this, getIntent());
    }
    @Override public void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); receive(this, intent); }
    static void receive(Context context, Intent intent) {
        app = context.getApplicationContext();
        String source = intent.getStringExtra("request");
        if (source == null) return;
        try {
            JSONObject request = new JSONObject(source);
            UUID.fromString(request.getString("id"));
            if (!request.has("javaOperation")) { nativeSubmit(source.getBytes(StandardCharsets.UTF_8)); return; }
            if (request.getString("javaOperation").contains("notification")) {
                NotificationRuntime.WORK.execute(() -> {
                    JSONObject result = new JSONObject();
                    try {
                        result.put("id",request.getString("id"));
                        NotificationRuntime runtime = NotificationRuntime.get(context);
                        switch (request.getString("javaOperation")) {
                            case "notifications":
                                org.json.JSONArray rows = new org.json.JSONArray();
                                for (NotificationRecord r : runtime.store.all()) rows.put(NotificationRuntime.json(r).put("state",r.state.name()));
                                result.put("data",rows); break;
                            case "cancel_notification": runtime.engine.cancel(request.getString("notificationID")); result.put("data",true); break;
                            case "restore_notifications": runtime.engine.restore(); result.put("data",true); break;
                            default: throw new IllegalArgumentException("Unknown notification command");
                        }
                    } catch (Exception error) {
                        NotificationRuntime.log("agent",error);
                        try { result.put("errorCode","native_failure"); } catch (Exception failure) { throw new IllegalStateException(failure); }
                    }
                    onResult(result.toString().getBytes(StandardCharsets.UTF_8));
                });
                return;
            }
            AlarmRuntime.WORK.execute(() -> {
                JSONObject result = new JSONObject();
                try {
                    result.put("id", request.getString("id"));
                    AlarmRuntime runtime = AlarmRuntime.get(context);
                    switch (request.getString("javaOperation")) {
                        case "snapshot": result.put("data", runtime.snapshot(false)); break;
                        case "stop":
                            String id = request.getString("alarmID");
                            runtime.engine.stop(id);
                            new android.os.Handler(android.os.Looper.getMainLooper()).post(() -> context.startService(
                                new Intent(context, PetAIAlarmService.class).setAction(PetAIAlarmService.STOP).putExtra("alarmID", id)));
                            result.put("data", true); break;
                        case "reconcile": runtime.engine.reconcile(false); result.put("data", true); break;
                        default: throw new IllegalArgumentException("Unsupported agent operation");
                    }
                } catch (Exception error) {
                    AlarmRuntime.logFailure("agent", error);
                    try { result.put("errorCode", "native_failure"); } catch (Exception ignored) { throw new IllegalStateException(ignored); }
                }
                onResult(result.toString().getBytes(StandardCharsets.UTF_8));
            });
        } catch (Exception error) { throw new IllegalArgumentException("Invalid agent request", error); }
    }
    public static void onResult(byte[] utf8) {
        try {
            JSONObject result = new JSONObject(new String(utf8, StandardCharsets.UTF_8));
            String id = result.getString("id"); UUID.fromString(id);
            File output = new File(app.getFilesDir(), "agent-" + id + ".json");
            try (FileOutputStream file = new FileOutputStream(output)) { file.write(utf8); file.getFD().sync(); }
        } catch (Exception error) { throw new IllegalStateException("Agent result could not be saved", error); }
    }
}
