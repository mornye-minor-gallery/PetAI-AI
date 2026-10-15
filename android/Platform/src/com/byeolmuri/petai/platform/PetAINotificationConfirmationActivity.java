package com.byeolmuri.petai.platform;

import android.Manifest;
import android.app.Activity;
import android.app.DatePickerDialog;
import android.app.TimePickerDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputFilter;
import android.widget.*;
import org.json.JSONObject;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

/** Approval edits data only; execution stays in the common tool-confirmation flow. */
public final class PetAINotificationConfirmationActivity extends Activity {
    private static final int NOTIFICATIONS = 51, EXACT = 52;
    private String id;
    private boolean permissionOnly, completed, waiting;
    private EditText title, body;
    private LocalDateTime dateTime;
    private Button dateButton, timeButton;
    private static final DateTimeFormatter DATE_TIME = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm");
    private Button approve;
    private TextView hint;
    private JSONObject arguments;
    public void onCreate(Bundle saved) {
        super.onCreate(saved);
        permissionOnly = getIntent().getBooleanExtra("permissionOnly", false);
        id = getIntent().getStringExtra("operationID");
        JSONObject request = permissionOnly ? null : PetAIPlatformBridge.attach(id, this);
        if (!permissionOnly && request == null) { finish(); return; }
        try {
            arguments = permissionOnly ? new JSONObject() : new JSONObject(saved == null ? request.getJSONObject("arguments").toString() : saved.getString("arguments"));
            waiting = saved != null && saved.getBoolean("waiting");
            LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
            int padding = (int)(20 * getResources().getDisplayMetrics().density); layout.setPadding(padding,padding,padding,padding);
            ScrollView scroll = new ScrollView(this); scroll.addView(layout); setContentView(scroll);
            setTitle(permissionOnly ? "예약 알림을 허용할까요?" : "알림을 예약할까요?");
            if (!permissionOnly) {
                title = field(layout,"제목", arguments.getString("title"), 120);
                body = field(layout,"내용", arguments.getString("body"), 500); body.setSingleLine(false);
                dateTime = LocalDateTime.parse(arguments.getString("dateTime"), DATE_TIME);
                dateButton = button(layout, dateTime.toLocalDate().toString(), () ->
                    new DatePickerDialog(this, (picker,y,m,d) -> {
                        dateTime = LocalDateTime.of(java.time.LocalDate.of(y,m+1,d), dateTime.toLocalTime());
                        dateButton.setText(dateTime.toLocalDate().toString());
                    },dateTime.getYear(),dateTime.getMonthValue()-1,dateTime.getDayOfMonth()).show());
                timeButton = button(layout, dateTime.toLocalTime().toString(), () ->
                    new TimePickerDialog(this,(picker,h,m) -> {
                        dateTime = dateTime.withHour(h).withMinute(m); timeButton.setText(dateTime.toLocalTime().toString());
                    },dateTime.getHour(),dateTime.getMinute(),true).show());
            }
            hint = new TextView(this); hint.setText("지정한 시간에 알려드리려면 알림과 정확한 알람 권한이 필요해요."); layout.addView(hint);
            approve = button(layout, permissionOnly ? "허용" : "예약", this::approve); approve.setEnabled(!waiting);
            button(layout,"취소", () -> finishWith("cancelled_by_user"));
        } catch (Exception error) { NotificationRuntime.log("confirmation", error); finishWith("invalid_arguments"); }
    }
    private EditText field(LinearLayout layout, String label, String value, int max) {
        TextView caption = new TextView(this); caption.setText(label); layout.addView(caption);
        EditText field = new EditText(this); field.setSingleLine(); field.setFilters(new InputFilter[]{new InputFilter.LengthFilter(max)});
        field.setText(value); layout.addView(field); return field;
    }
    private Button button(LinearLayout layout, String text, Runnable action) {
        Button b = new Button(this); b.setText(text); b.setOnClickListener(v -> action.run()); layout.addView(b); return b;
    }
    private boolean collect() {
        if (permissionOnly) return true;
        try {
            if (title.getText().toString().trim().isEmpty() || body.getText().toString().trim().isEmpty()) {
                hint.setText("제목과 내용을 적어 주세요."); return false;
            }
            arguments.put("title",title.getText().toString().trim()).put("body",body.getText().toString().trim())
                .put("dateTime",dateTime.format(DATE_TIME));
            return true;
        } catch (Exception error) { finishWith("invalid_arguments"); return false; }
    }
    private AndroidNotificationScheduler scheduler() { return NotificationRuntime.get(this).scheduler; }
    private void approve() {
        if (waiting || !collect()) return;
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            waiting = true; approve.setEnabled(false); requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATIONS); return;
        }
        if (!scheduler().notificationsAllowed()) { finishWith("permission_denied"); return; }
        if (!scheduler().exactAllowed()) {
            waiting = true; approve.setEnabled(false);
            try { startActivityForResult(new Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:" + getPackageName())), EXACT); }
            catch (RuntimeException error) { finishWith("permission_denied"); }
            return;
        }
        finishWith(null);
    }
    private void permissionReturned() {
        waiting = false; approve.setEnabled(true);
        // Permission grant is not approval of the reservation: keep the editable confirmation visible.
        hint.setText("권한 설정을 확인했어요. 내용을 확인한 뒤 다시 눌러 주세요.");
    }
    public void onRequestPermissionsResult(int request, String[] names, int[] results) {
        super.onRequestPermissionsResult(request,names,results);
        if (request == NOTIFICATIONS) {
            if (!scheduler().notificationsAllowed()) finishWith("permission_denied"); else permissionReturned();
        }
    }
    protected void onActivityResult(int request,int result,Intent data) {
        super.onActivityResult(request,result,data);
        if (request == EXACT) { if (!scheduler().exactAllowed()) finishWith("permission_denied"); else permissionReturned(); }
    }
    private void finishWith(String error) {
        if (!completed) {
            completed = true;
            if (permissionOnly) NotificationRuntime.WORK.execute(() -> {
                try { NotificationRuntime.get(this).permission(true); }
                catch (Exception failure) { NotificationRuntime.log("permission", failure); }
            });
            else if (id != null) PetAIPlatformBridge.finishConfirmation(id, error == null ? arguments : null, error);
        }
        finish();
    }
    public void onSaveInstanceState(Bundle saved) {
        if (arguments != null) { collect(); saved.putString("arguments", arguments.toString()); }
        saved.putBoolean("waiting", waiting); super.onSaveInstanceState(saved);
    }
    public void onDestroy() {
        if (isFinishing() && !isChangingConfigurations() && !completed) finishWith("cancelled_by_user");
        super.onDestroy();
    }
}
