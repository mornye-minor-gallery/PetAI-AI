package com.byeolmuri.petai.platform;

import android.content.*;

public final class PetAINotificationRestoreReceiver extends BroadcastReceiver {
    public void onReceive(Context context, Intent intent) {
        PendingResult pending = goAsync();
        NotificationRuntime.WORK.execute(() -> {
            try { NotificationRuntime.get(context).engine.restore(); }
            catch (Exception error) { NotificationRuntime.log("restore", error); }
            finally { pending.finish(); }
        });
    }
}
