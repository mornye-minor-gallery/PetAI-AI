package com.byeolmuri.petai.platform;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/** Explicit notification PendingIntent target, not an exported/deep-link entry point. */
public final class PetAINotificationOpenActivity extends Activity {
    public void onCreate(Bundle saved) {
        super.onCreate(saved);
        NotificationRuntime.WORK.execute(() -> {
            try {
                NotificationRuntime runtime = NotificationRuntime.get(this);
                NotificationRecord record = runtime.store.find(getIntent().getStringExtra("notificationID"));
                if (record != null && record.state == NotificationRecord.State.DELIVERED) runtime.store.opened(record);
            } catch (Exception error) { NotificationRuntime.log("open", error); }
            finally {
                runOnUiThread(() -> {
                    Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
                    if (launch != null) startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP));
                    finish();
                });
            }
        });
    }
}
