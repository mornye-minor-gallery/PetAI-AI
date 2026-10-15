package com.byeolmuri.petai.platform;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Looper;
import java.lang.ref.WeakReference;
import java.nio.charset.StandardCharsets;
import org.json.JSONException;
import org.json.JSONObject;

/** One process-owned JNI endpoint. No Unity callback or frame polling is required. */
public final class PetAIPlatformBridge {
    private static volatile Context context;
    private static WeakReference<Activity> foreground = new WeakReference<>(null);
    private static JSONObject confirmation;
    private static WeakReference<PetAIAlarmConfirmationActivity> presenter = new WeakReference<>(null);

    private PetAIPlatformBridge() {}
    private static native boolean nativeInstall();
    private static native boolean nativeSetTimeZone(byte[] identifier);
    private static native void nativeComplete(byte[] json);

    // Called after Swift's main-queue bootstrap, on Android's UI thread.
    public static synchronized void install(Activity activity) {
        if (Looper.myLooper() != Looper.getMainLooper()) throw new IllegalStateException("Platform installation requires UI thread");
        System.loadLibrary("PetAIAndroid");
        if (!nativeInstall()) throw new IllegalStateException("Platform JNI registration failed");
        applyTimeZone();
        foreground = new WeakReference<>(activity);
        if (context != null) return;
        context = activity.getApplicationContext();
        ((Application) context).registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
            public void onActivityResumed(Activity value) {
                applyTimeZone();
                if (value instanceof PetAIAlarmConfirmationActivity) return;
                foreground = new WeakReference<>(value);
                AlarmRuntime.WORK.execute(() -> {
                    try { AlarmRuntime.get(context).engine.reconcile(false); }
                    catch (Exception error) { AlarmRuntime.logFailure("foreground_reconcile", error); }
                });
            }
            public void onActivityPaused(Activity value) { if (foreground.get() == value) foreground.clear(); }
            public void onActivityCreated(Activity a, Bundle b) {}
            public void onActivityStarted(Activity a) {}
            public void onActivityStopped(Activity a) {}
            public void onActivitySaveInstanceState(Activity a, Bundle b) {}
            public void onActivityDestroyed(Activity a) {}
        });
        AlarmRuntime.WORK.execute(() -> {
            try { AlarmRuntime.get(context).engine.reconcile(false); }
            catch (Exception error) { AlarmRuntime.logFailure("initial_reconcile", error); }
        });
    }

    private static void applyTimeZone() {
        if (!nativeSetTimeZone(java.util.TimeZone.getDefault().getID().getBytes(StandardCharsets.UTF_8)))
            throw new IllegalStateException("Swift could not apply the Android time zone");
    }
    static void refreshTimeZoneIfInstalled() {
        // A boot/alarm receiver must not load Swift just to restore reservations.
        if (context != null) applyTimeZone();
    }

    public static void submit(byte[] utf8) {
        final JSONObject request;
        try { request = new JSONObject(new String(utf8, StandardCharsets.UTF_8)); }
        catch (JSONException error) { throw new IllegalArgumentException("Invalid platform JSON"); }
        final String id = request.optString("id");
        if (id.isEmpty() || id.length() > 128) throw new IllegalArgumentException("Invalid platform correlation ID");
        String operation = request.optString("operation");
        if (operation.equals("confirm") || operation.equals("cancel_confirmation")) {
            new android.os.Handler(Looper.getMainLooper()).post(() -> {
                if (operation.equals("confirm")) beginConfirmation(request);
                else cancelConfirmation(request.optString("targetID"));
            });
            return;
        }
        AlarmRuntime.WORK.execute(() -> {
            try {
                if (context == null) throw new AlarmFailure("data_unavailable");
                AlarmRuntime runtime = AlarmRuntime.get(context);
                JSONObject result;
                if (operation.equals("execute")) result = runtime.execute(request);
                else if (operation.equals("snapshot")) result = runtime.snapshot(true);
                else throw new AlarmFailure("invalid_arguments");
                reply(id, result, null);
            } catch (AlarmFailure error) { reply(id, null, error.code); }
            catch (JSONException error) { reply(id, null, "invalid_arguments"); }
            catch (Exception error) { AlarmRuntime.logFailure("request", error); reply(id, null, "native_failure"); }
        });
    }

    private static synchronized void beginConfirmation(JSONObject request) {
        String id = request.optString("id");
        Activity activity = foreground.get();
        if (activity == null || activity.isFinishing() || activity.isDestroyed()) { reply(id, null, "data_unavailable"); return; }
        if (confirmation != null) { reply(id, null, "native_failure"); return; }
        confirmation = request;
        try { activity.startActivity(new Intent(activity, PetAIAlarmConfirmationActivity.class).putExtra("operationID", id)); }
        catch (RuntimeException error) { confirmation = null; reply(id, null, "native_failure"); }
    }
    static synchronized JSONObject attach(String id, PetAIAlarmConfirmationActivity activity) {
        if (confirmation == null || !id.equals(confirmation.optString("id"))) return null;
        presenter = new WeakReference<>(activity);
        return confirmation;
    }
    static synchronized void finishConfirmation(String id, JSONObject arguments, String error) {
        if (confirmation == null || !id.equals(confirmation.optString("id"))) return;
        confirmation = null; presenter.clear();
        reply(id, arguments, error);
    }
    private static synchronized void cancelConfirmation(String id) {
        if (confirmation == null || !id.equals(confirmation.optString("id"))) return;
        PetAIAlarmConfirmationActivity activity = presenter.get();
        finishConfirmation(id, null, "cancelled_by_user");
        if (activity != null) activity.finish();
    }
    private static void reply(String id, JSONObject data, String error) {
        try {
            JSONObject reply = new JSONObject().put("id", id);
            if (error == null) reply.put("data", data == null ? new JSONObject() : data);
            else reply.put("errorCode", error);
            nativeComplete(reply.toString().getBytes(StandardCharsets.UTF_8));
        } catch (JSONException failure) { throw new IllegalStateException("Platform reply encoding failed", failure); }
    }
}
