package com.byeolmuri.petai.platform;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class PetAIAlarmReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (!AndroidAlarmScheduler.DELIVER.equals(intent.getAction())) return;
        String id = intent.getStringExtra("alarmID");
        if (id == null) return;
        PendingResult pending = goAsync();
        AlarmRuntime.WORK.execute(() -> {
            try {
                AlarmRecord record = AlarmRuntime.get(context).engine.find(id);
                if (record != null && record.active() && record.state != AlarmRecord.State.RINGING) context.startForegroundService(
                    new Intent(context, PetAIAlarmService.class).setAction(PetAIAlarmService.RING).putExtra("alarmID", id));
            } catch (Exception error) {
                AlarmRuntime.logFailure("delivery", error);
                try { AlarmRuntime.get(context).engine.failDelivery(id, "native_failure"); }
                catch (Exception storageError) { AlarmRuntime.logFailure("delivery_state", storageError); }
            }
            finally { pending.finish(); }
        });
    }
}
