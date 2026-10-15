package com.byeolmuri.petai.platform;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Explicit shell-command endpoint in the separate debug APK only. */
public final class AlarmAgentReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) { PetAIAlarmAgent.receive(context, intent); }
}
