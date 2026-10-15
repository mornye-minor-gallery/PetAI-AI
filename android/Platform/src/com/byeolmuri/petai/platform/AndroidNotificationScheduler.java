package com.byeolmuri.petai.platform;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;

final class AndroidNotificationScheduler implements NotificationEngine.Delivery {
    static final String CHANNEL = "petai.reminders.v1";
    private final Context context;
    private final AlarmManager alarms;
    private final NotificationManager notifications;
    AndroidNotificationScheduler(Context context) {
        this.context = context.getApplicationContext();
        alarms = context.getSystemService(AlarmManager.class); notifications = context.getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel(CHANNEL, "별무리 예약 알림", NotificationManager.IMPORTANCE_DEFAULT));
    }
    boolean exactAllowed() { return Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms(); }
    boolean notificationsAllowed() {
        NotificationChannel channel = notifications.getNotificationChannel(CHANNEL);
        return notifications.areNotificationsEnabled() && channel != null && channel.getImportance() != NotificationManager.IMPORTANCE_NONE
            && (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED);
    }
    public boolean permitted() { return exactAllowed() && notificationsAllowed(); }
    public void schedule(NotificationRecord record) throws NotificationFailure {
        if (!permitted()) throw new NotificationFailure("permission_denied");
        try { alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, record.at, trigger(record.id, PendingIntent.FLAG_UPDATE_CURRENT)); }
        catch (SecurityException error) { throw new NotificationFailure("permission_denied"); }
    }
    public void cancel(NotificationRecord record) {
        PendingIntent trigger = trigger(record.id, PendingIntent.FLAG_NO_CREATE);
        if (trigger != null) { alarms.cancel(trigger); trigger.cancel(); }
        notifications.cancel(record.id, 0);
    }
    public void post(NotificationRecord record) throws NotificationFailure {
        if (!permitted()) throw new NotificationFailure("permission_denied");
        Intent open = new Intent(context, PetAINotificationOpenActivity.class)
            .setData(Uri.parse("petai-reminder://open/" + record.id)).putExtra("notificationID", record.id);
        PendingIntent tap = PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification notification = new Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_popup_reminder).setContentTitle(record.title).setContentText(record.body)
            .setStyle(new Notification.BigTextStyle().bigText(record.body)).setContentIntent(tap)
            .setAutoCancel(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE).build();
        notifications.notify(record.id, 0, notification);
    }
    private PendingIntent trigger(String id, int flags) {
        Intent intent = new Intent(context, PetAINotificationReceiver.class)
            .setAction("com.byeolmuri.petai.NOTIFICATION_DELIVER").setData(Uri.parse("petai-reminder://reservation/" + id))
            .putExtra("notificationID", id);
        return PendingIntent.getBroadcast(context, 0, intent, flags | PendingIntent.FLAG_IMMUTABLE);
    }
}
