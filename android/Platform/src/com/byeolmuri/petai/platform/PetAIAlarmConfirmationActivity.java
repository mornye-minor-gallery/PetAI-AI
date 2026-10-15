package com.byeolmuri.petai.platform;

import android.Manifest;
import android.app.Activity;
import android.app.DatePickerDialog;
import android.app.TimePickerDialog;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputFilter;
import android.text.InputType;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.time.LocalDate;
import java.util.Locale;
import org.json.JSONObject;

/** Native user approval; it never executes an alarm itself. */
public final class PetAIAlarmConfirmationActivity extends Activity {
    private static final int NOTIFICATIONS = 41, EXACT = 42;
    private String id, tool;
    private JSONObject arguments;
    private EditText label, duration;
    private TextView error;
    private Button dateButton, timeButton, approve;
    private LinearLayout layout;
    private boolean completed, permissionPending;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        id = getIntent().getStringExtra("operationID");
        JSONObject request = id == null ? null : PetAIPlatformBridge.attach(id, this);
        if (request == null) { finish(); return; }
        try {
            tool = request.getString("tool");
            if (!tool.equals("create_alarm") && !tool.equals("create_timer") && !tool.equals("list_alarms"))
                throw new IllegalArgumentException("Unsupported confirmation tool");
            arguments = new JSONObject(saved == null ? request.getJSONObject("arguments").toString() : saved.getString("arguments"));
            permissionPending = saved != null && saved.getBoolean("permissionPending");
            layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
            int padding = (int)(20 * getResources().getDisplayMetrics().density); layout.setPadding(padding, padding, padding, padding);
            setContentView(layout);
            setTitle(tool.equals("create_alarm") ? "알람을 설정할까요?" : tool.equals("create_timer") ? "타이머를 시작할까요?" : "별무리 알람을 확인할까요?");
            if (!tool.equals("list_alarms")) {
                label = new EditText(this); label.setSingleLine(true); label.setFilters(new InputFilter[]{new InputFilter.LengthFilter(80)});
                label.setHint("이름"); label.setText(arguments.getString("label")); layout.addView(label);
                if (tool.equals("create_alarm")) addDateTime();
                else {
                    TextView description = new TextView(this); description.setText("시간 (초)"); layout.addView(description);
                    duration = new EditText(this); duration.setInputType(InputType.TYPE_CLASS_NUMBER);
                    duration.setText(String.valueOf(arguments.getInt("durationSeconds"))); layout.addView(duration);
                }
                TextView permission = new TextView(this);
                permission.setText("앱을 닫아도 울리도록 정확한 알람과 알림 권한을 사용해요."); layout.addView(permission);
            } else {
                TextView description = new TextView(this); description.setText("이 기기의 별무리에서 만든 알람과 타이머만 확인해요."); layout.addView(description);
                button("알람 관리", () -> startActivity(new Intent(this, PetAIAlarmListActivity.class)));
            }
            error = new TextView(this); layout.addView(error);
            approve = button(tool.equals("list_alarms") ? "확인" : "설정", this::approve);
            approve.setEnabled(!permissionPending);
            button("취소", () -> finishWith(null, "cancelled_by_user"));
        } catch (Exception failure) { AlarmRuntime.logFailure("confirmation", failure); finishWith(null, "invalid_arguments"); }
    }
    private Button button(String text, Runnable action) {
        Button button = new Button(this); button.setText(text); button.setOnClickListener(view -> action.run()); layout.addView(button);
        return button;
    }
    private void addDateTime() throws Exception {
        LocalDate date = LocalDate.parse(arguments.getString("date"));
        dateButton = button(date.toString(), () -> {
            LocalDate current = LocalDate.parse(arguments.optString("date"));
            new DatePickerDialog(this, (picker, year, month, day) -> {
                try { arguments.put("date", LocalDate.of(year, month + 1, day).toString()); dateButton.setText(arguments.getString("date")); }
                catch (Exception failure) { error.setText("날짜를 다시 골라 주세요."); }
            }, current.getYear(), current.getMonthValue() - 1, current.getDayOfMonth()).show();
        });
        timeButton = button(timeText(), () -> new TimePickerDialog(this, (picker, hour, minute) -> {
            try { arguments.put("hour", hour).put("minute", minute); timeButton.setText(timeText()); }
            catch (Exception failure) { error.setText("시간을 다시 골라 주세요."); }
        }, arguments.optInt("hour"), arguments.optInt("minute"), true).show());
    }
    private String timeText() { return String.format(Locale.ROOT, "%02d:%02d", arguments.optInt("hour"), arguments.optInt("minute")); }
    private boolean collect() {
        if (tool.equals("list_alarms")) return true;
        try {
            String text = label.getText().toString().trim();
            if (text.isEmpty()) { label.setError("이름을 적어 주세요."); return false; }
            arguments.put("label", text);
            if (duration != null) {
                int seconds = Integer.parseInt(duration.getText().toString());
                if (seconds < 1 || seconds > 86_400) throw new IllegalArgumentException();
                arguments.put("durationSeconds", seconds);
            }
            return true;
        } catch (Exception failure) { error.setText("타이머는 1초부터 24시간까지 설정할 수 있어요."); return false; }
    }
    private void approve() {
        if (permissionPending || !collect()) return;
        if (tool.equals("list_alarms")) { finishWith(arguments, null); return; }
        AndroidAlarmScheduler scheduler = AlarmRuntime.get(this).scheduler;
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            permissionPending = true; approve.setEnabled(false);
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATIONS); return;
        }
        if (!scheduler.notificationsAllowed()) { finishWith(null, "permission_denied"); return; }
        requireExact();
    }
    private void requireExact() {
        if (AlarmRuntime.get(this).scheduler.exactAllowed()) { finishWith(arguments, null); return; }
        permissionPending = true; approve.setEnabled(false);
        try { startActivityForResult(new Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
            Uri.parse("package:" + getPackageName())), EXACT); }
        catch (RuntimeException failure) { finishWith(null, "permission_denied"); }
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request != NOTIFICATIONS) return;
        permissionPending = false;
        if (!AlarmRuntime.get(this).scheduler.notificationsAllowed()) finishWith(null, "permission_denied");
        else requireExact();
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == EXACT) {
            permissionPending = false;
            if (AlarmRuntime.get(this).scheduler.permitted()) finishWith(arguments, null);
            else finishWith(null, "permission_denied");
        }
    }
    private void finishWith(JSONObject result, String failure) {
        if (!completed && id != null) { completed = true; PetAIPlatformBridge.finishConfirmation(id, result, failure); }
        finish();
    }
    @Override public void onSaveInstanceState(Bundle saved) {
        if (arguments != null) { collect(); saved.putString("arguments", arguments.toString()); }
        saved.putBoolean("permissionPending", permissionPending);
        super.onSaveInstanceState(saved);
    }
    @Override public void onDestroy() {
        if (isFinishing() && !isChangingConfigurations() && !completed && id != null)
            PetAIPlatformBridge.finishConfirmation(id, null, "cancelled_by_user");
        super.onDestroy();
    }
}
