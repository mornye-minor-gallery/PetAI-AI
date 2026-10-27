package com.byeolmuri.petai.platform;

import android.app.AlarmManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class PetAIAlarmRestoreReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        boolean reboot = Intent.ACTION_BOOT_COMPLETED.equals(action) || Intent.ACTION_LOCKED_BOOT_COMPLETED.equals(action);
        if (!reboot && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(action) && !Intent.ACTION_TIME_CHANGED.equals(action)
                && !Intent.ACTION_TIMEZONE_CHANGED.equals(action)
                && !AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED.equals(action)) return;
        if (Intent.ACTION_TIMEZONE_CHANGED.equals(action)) PetAIPlatformBridge.refreshTimeZoneIfInstalled();
        PendingResult pending = goAsync();
        AlarmRuntime.WORK.execute(() -> {
            try { AlarmRuntime.get(context).engine.reconcile(reboot); }
            catch (Exception error) { AlarmRuntime.logFailure("restore", error); }
            finally { pending.finish(); }
        });
    }
}
