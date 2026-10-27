package com.byeolmuri.petai.platform;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import org.json.*;

/** Unity feature events reuse its existing coordinator; Java remains the reservation authority. */
public final class PetAINotificationBridge {
    private static volatile Context context;
    private PetAINotificationBridge() {}
    public static synchronized void install(Activity activity) {
        if (context != null) return;
        context = activity.getApplicationContext();
        ((Application) context).registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
            public void onActivityResumed(Activity a) {
                if (a instanceof PetAINotificationConfirmationActivity || a instanceof PetAINotificationOpenActivity) return;
                refresh();
            }
            public void onActivityPaused(Activity a) {}
            public void onActivityCreated(Activity a, Bundle b) {}
            public void onActivityStarted(Activity a) {}
            public void onActivityStopped(Activity a) {}
            public void onActivitySaveInstanceState(Activity a, Bundle b) {}
            public void onActivityDestroyed(Activity a) {}
        });
        refresh();
    }
    private static void refresh() {
        NotificationRuntime.WORK.execute(() -> {
            try {
                NotificationRuntime runtime = NotificationRuntime.get(context);
                runtime.engine.restore(); runtime.permission(false); runtime.snapshot();
                emitNextOpened(runtime);
            } catch (Exception error) { NotificationRuntime.log("refresh", error); failure("refresh", "", "", "native_failure"); }
        });
    }
    public static void requestPermission(Activity activity) {
        activity.runOnUiThread(() -> activity.startActivity(new Intent(activity, PetAINotificationConfirmationActivity.class)
            .putExtra("permissionOnly", true)));
    }
    public static void submit(String operation, String payload) {
        if (context == null) throw new IllegalStateException("Notification bridge is not installed");
        NotificationRuntime.WORK.execute(() -> {
            String requestID = "", notificationID = "";
            try {
                NotificationRuntime runtime = NotificationRuntime.get(context);
                JSONObject value = new JSONObject(payload);
                requestID = value.optString("requestId"); notificationID = value.optString("notificationId");
                switch (operation) {
                    case "permission": runtime.permission(false); break;
                    case "schedule": runtime.schedule(value); break;
                    case "list": runtime.snapshot(); break;
                    case "delete":
                        runtime.engine.cancel(notificationID);
                        NotificationRuntime.EVENTS.add(new JSONObject().put("type", "notification_result").put("operation", "delete")
                            .put("notificationId", notificationID).put("success", true).toString());
                        runtime.snapshot(); break;
                    case "delete_all": runtime.engine.cancelAll(); runtime.snapshot(); break;
                    default: throw new NotificationFailure("invalid_arguments");
                }
            } catch (Exception error) {
                NotificationRuntime.log(operation, error);
                failure(operation, requestID, notificationID, error instanceof NotificationFailure ? ((NotificationFailure) error).code : "native_failure");
            }
        });
    }
    public static String pollEvent() {
        String event = NotificationRuntime.EVENTS.poll();
        if (event == null) return "";
        return event;
    }
    public static void acknowledgeOpened(String id) {
        NotificationRuntime.WORK.execute(() -> {
            try {
                NotificationRuntime runtime = NotificationRuntime.get(context);
                runtime.store.acknowledgeOpened(id);
                emitNextOpened(runtime);
            }
            catch (Exception error) { NotificationRuntime.log("acknowledge_open", error); }
        });
    }
    private static void emitNextOpened(NotificationRuntime runtime) throws JSONException {
        String[] opened = runtime.store.nextOpened();
        if (opened != null) NotificationRuntime.EVENTS.add(new JSONObject().put("type", "notification_opened")
            .put("notificationId", opened[0]).put("deepLink", opened[1]).toString());
    }
    private static void failure(String operation, String request, String id, String code) {
        try {
            JSONObject event = new JSONObject().put("type", "notification_result").put("operation", operation)
                .put("requestId", request).put("notificationId", id).put("success", false).put("failureCode", code);
            if (operation.equals("permission") || operation.equals("refresh"))
                event.put("type", "permission_result").put("permission", "notifications").put("permissionStatus", "Failed");
            NotificationRuntime.EVENTS.add(event.toString());
        }
        catch (JSONException error) { throw new IllegalStateException(error); }
    }
}
