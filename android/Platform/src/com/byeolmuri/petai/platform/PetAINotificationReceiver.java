package com.byeolmuri.petai.platform;

import android.content.*;

public final class PetAINotificationReceiver extends BroadcastReceiver {
    public void onReceive(Context context, Intent intent) {
        PendingResult pending = goAsync();
        NotificationRuntime.WORK.execute(() -> {
            try { NotificationRuntime.get(context).engine.deliver(intent.getStringExtra("notificationID")); }
            catch (Exception error) { NotificationRuntime.log("delivery", error); }
            finally { pending.finish(); }
        });
    }
}
