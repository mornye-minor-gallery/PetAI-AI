package com.byeolmuri.petai.platform;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import org.json.JSONArray;
import org.json.JSONObject;

/** Reachable from Android's next-alarm indicator and ringing notification. */
public final class PetAIAlarmListActivity extends Activity {
    private LinearLayout rows;
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved); setTitle("별무리 알람");
        ScrollView scroll = new ScrollView(this); rows = new LinearLayout(this); rows.setOrientation(LinearLayout.VERTICAL);
        int padding = (int)(20 * getResources().getDisplayMetrics().density); rows.setPadding(padding, padding, padding, padding);
        scroll.addView(rows); setContentView(scroll);
    }
    @Override public void onResume() { super.onResume(); refresh(); }
    private void refresh() {
        AlarmRuntime.WORK.execute(() -> {
            try {
                JSONArray records = AlarmRuntime.get(this).snapshot(false).getJSONArray("alarms");
                runOnUiThread(() -> render(records));
            } catch (Exception error) {
                AlarmRuntime.logFailure("management_list", error);
                runOnUiThread(() -> { if (!isDestroyed()) { rows.removeAllViews(); text("알람을 읽지 못했어요. 다시 열어 주세요."); } });
            }
        });
    }
    private void text(String message) { TextView view = new TextView(this); view.setText(message); rows.addView(view); }
    private void render(JSONArray records) {
        if (isDestroyed()) return;
        rows.removeAllViews();
        if (records.length() == 0) text("예약된 알람이 없어요.");
        for (int i = 0; i < records.length(); i++) {
            JSONObject record = records.optJSONObject(i);
            String id = record.optString("id"), state = record.optString("state");
            String time = DateTimeFormatter.ofPattern("M월 d일 HH:mm").withZone(ZoneId.systemDefault())
                .format(Instant.parse(record.optString("scheduledAt")));
            text(record.optString("label") + "\n" + time + (state.equals("blocked") ? "\n알람과 알림 권한을 확인해 주세요." : ""));
            Button cancel = new Button(this); cancel.setText(state.equals("alerting") ? "중지" : "취소"); rows.addView(cancel);
            cancel.setOnClickListener(view -> {
                cancel.setEnabled(false);
                AlarmRuntime.WORK.execute(() -> {
                    try {
                        AlarmRuntime.get(this).engine.stop(id);
                        // The row may have changed from scheduled to ringing since
                        // rendering. Always stop a possible live audio owner too.
                        runOnUiThread(() -> startService(new Intent(this, PetAIAlarmService.class)
                            .setAction(PetAIAlarmService.STOP).putExtra("alarmID", id)));
                        refresh();
                    }
                    catch (Exception error) {
                        AlarmRuntime.logFailure("management_cancel", error);
                        runOnUiThread(() -> { cancel.setEnabled(true); text("취소하지 못했어요. 다시 시도해 주세요."); });
                    }
                });
            });
        }
        Button close = new Button(this); close.setText("닫기"); close.setOnClickListener(view -> finish()); rows.addView(close);
    }
}
