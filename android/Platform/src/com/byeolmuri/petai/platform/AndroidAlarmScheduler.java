package com.byeolmuri.petai.platform;

import android.Manifest;
import android.app.AlarmManager;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;

final class AndroidAlarmScheduler implements AlarmEngine.Scheduler {
    static final String CHANNEL = "petai.alarms.v1";
    static final String DELIVER = "com.byeolmuri.petai.ALARM_DELIVER";
    private final Context context;
    private final AlarmManager manager;
    AndroidAlarmScheduler(Context context) {
        this.context = context.getApplicationContext();
        manager = context.getSystemService(AlarmManager.class);
        NotificationChannel channel = new NotificationChannel(CHANNEL, "별무리 알람", NotificationManager.IMPORTANCE_HIGH);
        // Audio/vibration belong to the short-lived ringing service, not two competing sources.
        channel.setSound(null, null); channel.enableVibration(false);
        context.getSystemService(NotificationManager.class).createNotificationChannel(channel);
    }
    boolean exactAllowed() { return Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms(); }
    boolean notificationsAllowed() {
        NotificationManager notifications = context.getSystemService(NotificationManager.class);
        NotificationChannel channel = notifications.getNotificationChannel(CHANNEL);
        return notifications.areNotificationsEnabled() && channel != null
            && channel.getImportance() != NotificationManager.IMPORTANCE_NONE
            && (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED);
    }
    @Override public boolean permitted() { return exactAllowed() && notificationsAllowed(); }
    @Override public void schedule(AlarmRecord record) throws AlarmFailure {
        if (!permitted()) throw new AlarmFailure("permission_denied");
        PendingIntent delivery = delivery(record.id, PendingIntent.FLAG_UPDATE_CURRENT);
        try {
            if (record.kind.equals("timer")) {
                manager.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, record.elapsedDeadline, delivery);
            } else {
                manager.setAlarmClock(new AlarmManager.AlarmClockInfo(record.wallMillis, managementIntent(context)), delivery);
            }
        } catch (SecurityException error) { throw new AlarmFailure("permission_denied", error); }
        catch (RuntimeException error) { throw new AlarmFailure("native_failure", error); }
    }
    @Override public void cancel(AlarmRecord record) throws AlarmFailure {
        try {
            PendingIntent delivery = delivery(record.id, PendingIntent.FLAG_NO_CREATE);
            if (delivery != null) { manager.cancel(delivery); delivery.cancel(); }
        } catch (RuntimeException error) { throw new AlarmFailure("native_failure", error); }
    }
    private PendingIntent delivery(String id, int flags) {
        // URI identity, not hashCode, keeps unrelated reservations distinct.
        Intent intent = new Intent(context, PetAIAlarmReceiver.class).setAction(DELIVER)
            .setData(Uri.parse("petai-alarm://reservation/" + id)).putExtra("alarmID", id);
        return PendingIntent.getBroadcast(context, 0, intent, flags | PendingIntent.FLAG_IMMUTABLE);
    }
    static PendingIntent managementIntent(Context context) {
        Intent intent = new Intent(context, PetAIAlarmListActivity.class).setData(Uri.parse("petai-alarm://manage"));
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }
}
