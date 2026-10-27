package com.byeolmuri.petai.platform;

import android.app.Notification;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.Ringtone;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.Log;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;

/** Exists only while alarms are ringing. No model, Unity or Swift initialization. */
public final class PetAIAlarmService extends Service {
    static final String RING = "com.byeolmuri.petai.ALARM_RING";
    static final String STOP = "com.byeolmuri.petai.ALARM_STOP";
    static final String STOP_ALL = "com.byeolmuri.petai.ALARM_STOP_ALL";
    private static final int NOTIFICATION_ID = 0x504554;
    // Prevent an abandoned alarm from holding audio and a wake lock indefinitely.
    private static final long MAX_RING_MILLIS = 5 * 60_000L;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String, String> ringing = new LinkedHashMap<>();
    private final Map<String, Runnable> deadlines = new LinkedHashMap<>();
    private Ringtone ringtone;
    private Vibrator vibrator;
    private AudioManager audioManager;
    private AudioFocusRequest focus;
    private PowerManager.WakeLock wakeLock;
    private boolean destroyed;

    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public int onStartCommand(Intent intent, int flags, int startID) {
        if (intent == null) { stopSelfResult(startID); return START_NOT_STICKY; }
        String action = intent.getAction(), id = intent.getStringExtra("alarmID");
        if (STOP_ALL.equals(action)) { stopAll(); return START_NOT_STICKY; }
        if (STOP.equals(action)) { stopAlarm(id); return START_NOT_STICKY; }
        if (!RING.equals(action) || id == null) { stopSelfResult(startID); return START_NOT_STICKY; }
        final AlarmRuntime runtime;
        try {
            runtime = AlarmRuntime.get(this);
            foregroundNotification("별무리 알람");
        } catch (RuntimeException error) {
            AlarmRuntime.logFailure("foreground_service", error);
            AlarmRuntime.WORK.execute(() -> {
                try { AlarmRuntime.get(this).engine.failDelivery(id, "native_failure"); }
                catch (Exception failure) { AlarmRuntime.logFailure("foreground_service_state", failure); }
            });
            stopSelfResult(startID); return START_NOT_STICKY;
        }
        AlarmRuntime.WORK.execute(() -> {
            try {
                boolean claimed = runtime.engine.claim(id);
                String label = claimed ? runtime.store.label(runtime.engine.find(id)) : null;
                main.post(() -> {
                    if (destroyed) { stopAlarm(id); return; }
                    if (!claimed) {
                        if (ringing.isEmpty()) stopSelfResult(startID); else refreshNotification();
                        return;
                    }
                    ringing.put(id, label);
                    Runnable deadline = () -> stopAlarm(id);
                    deadlines.put(id, deadline); main.postDelayed(deadline, MAX_RING_MILLIS);
                    try { startAudio(); refreshNotification(); Log.i("PetAI.Alarms", "ringing count=" + ringing.size()); }
                    catch (RuntimeException error) {
                        AlarmRuntime.logFailure("audio", error);
                        AlarmRuntime.WORK.execute(() -> {
                            try { runtime.engine.failDelivery(id, "native_failure"); }
                            catch (Exception failure) { AlarmRuntime.logFailure("audio_state", failure); }
                            main.post(() -> removeRinging(id));
                        });
                    }
                });
            } catch (Exception error) {
                AlarmRuntime.logFailure("claim", error);
                try { runtime.engine.failDelivery(id, "native_failure"); }
                catch (Exception failure) { AlarmRuntime.logFailure("claim_state", failure); }
                main.post(() -> { if (ringing.isEmpty()) stopSelfResult(startID); });
            }
        });
        return START_NOT_STICKY;
    }

    private void foregroundNotification(String label) {
        Intent stop = new Intent(this, PetAIAlarmService.class).setAction(STOP_ALL);
        PendingIntent stopAction = PendingIntent.getService(this, 0, stop,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification notification = new Notification.Builder(this, AndroidAlarmScheduler.CHANNEL)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm).setContentTitle(label)
            .setContentText(ringing.size() > 1 ? "알람 " + ringing.size() + "개가 울리고 있어요." : "중지를 누르면 알람이 멈춰요.")
            .setCategory(Notification.CATEGORY_ALARM).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(AndroidAlarmScheduler.managementIntent(this))
            .addAction(new Notification.Action.Builder(null, "중지", stopAction).build())
            .setOngoing(true).setOnlyAlertOnce(true).build();
        // systemExempted 는 API 34 에 생긴 유형이다. 그 아래에서는 매니페스트의 유형을 그대로 쓴다.
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED);
        else startForeground(NOTIFICATION_ID, notification);
    }
    private void refreshNotification() {
        if (!ringing.isEmpty()) foregroundNotification(ringing.values().iterator().next());
    }
    private void startAudio() {
        if (ringtone != null) { if (wakeLock != null) wakeLock.acquire(MAX_RING_MILLIS + 5_000); return; }
        AudioAttributes attributes = new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build();
        audioManager = getSystemService(AudioManager.class);
        focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attributes).setOnAudioFocusChangeListener(change -> {
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) stopAll();
            }, main).build();
        if (audioManager.requestAudioFocus(focus) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
            throw new IllegalStateException("Alarm audio focus was denied");
        Uri sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
        ringtone = RingtoneManager.getRingtone(this, sound);
        if (ringtone == null) throw new IllegalStateException("Default alarm audio unavailable");
        ringtone.setAudioAttributes(attributes); ringtone.setLooping(true); ringtone.play();
        vibrator = getSystemService(Vibrator.class);
        if (vibrator != null && vibrator.hasVibrator()) vibrator.vibrate(
            VibrationEffect.createWaveform(new long[]{0, 500, 500}, 0), attributes);
        wakeLock = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PetAI:AlarmRinging");
        wakeLock.setReferenceCounted(false);
        wakeLock.acquire(MAX_RING_MILLIS + 5_000);
    }
    private void stopAll() {
        AlarmRuntime.WORK.execute(() -> {
            try {
                for (AlarmRecord record : AlarmRuntime.get(this).engine.active())
                    if (record.state == AlarmRecord.State.RINGING) AlarmRuntime.get(this).engine.stop(record.id);
            } catch (Exception error) { AlarmRuntime.logFailure("stop_all", error); }
            main.post(() -> {
                for (String id : new ArrayList<>(ringing.keySet())) removeRinging(id);
                if (ringing.isEmpty()) { releaseAudio(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); }
            });
        });
    }
    private void stopAlarm(String id) {
        if (id == null) { if (ringing.isEmpty()) stopSelf(); return; }
        AlarmRuntime.WORK.execute(() -> {
            try { AlarmRuntime.get(this).engine.stop(id); }
            catch (Exception error) { AlarmRuntime.logFailure("stop", error); }
            main.post(() -> removeRinging(id));
        });
    }
    private void removeRinging(String id) {
        ringing.remove(id);
        Runnable deadline = deadlines.remove(id); if (deadline != null) main.removeCallbacks(deadline);
        if (destroyed) { releaseAudio(); return; }
        if (ringing.isEmpty()) { releaseAudio(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); }
        else refreshNotification();
    }
    private void releaseAudio() {
        if (ringtone != null) { ringtone.stop(); ringtone = null; }
        if (vibrator != null) { vibrator.cancel(); vibrator = null; }
        if (audioManager != null && focus != null) audioManager.abandonAudioFocusRequest(focus);
        focus = null;
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        wakeLock = null;
    }
    @Override public void onDestroy() {
        destroyed = true;
        // Do not discard in-flight claim callbacks: they must observe destroyed
        // and finish their durable ringing state instead of leaving it stranded.
        for (Runnable deadline : deadlines.values()) main.removeCallbacks(deadline);
        deadlines.clear();
        ArrayList<String> interrupted = new ArrayList<>(ringing.keySet());
        releaseAudio();
        AlarmRuntime.WORK.execute(() -> {
            for (String id : interrupted) {
                try { AlarmRuntime.get(this).engine.stop(id); }
                catch (Exception error) { AlarmRuntime.logFailure("service_cleanup", error); }
            }
        });
        super.onDestroy();
    }
}
