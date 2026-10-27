package com.byeolmuri.petai.platform;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.DatePickerDialog;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.widget.*;
import com.google.android.gms.common.GoogleApiAvailability;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.concurrent.CompletableFuture;
import org.json.JSONObject;

/** Consent belongs here; the model can request a query but cannot enable recording. */
public final class PetAIStepConfirmationActivity extends Activity {
    private static final int PERMISSION = 61;
    private String id;
    private JSONObject arguments;
    private LinearLayout layout;
    private TextView status, error;
    private Button approve;
    private Spinner aggregation;
    private LocalStepRecording recording;
    private boolean completed, loading, permissionPending;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        id = getIntent().getStringExtra("operationID");
        JSONObject request = id == null ? null : PetAIPlatformBridge.attach(id, this);
        if (request == null) { finish(); return; }
        try {
            recording = StepRuntime.get(this);
            arguments = new JSONObject(saved == null ? request.getJSONObject("arguments").toString() : saved.getString("arguments"));
            permissionPending = saved != null && saved.getBoolean("permissionPending");
            setTitle("걸음 수를 확인할까요?");
            layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
            int pad = (int)(20 * getResources().getDisplayMetrics().density); layout.setPadding(pad,pad,pad,pad);
            ScrollView scroll = new ScrollView(this); scroll.addView(layout); setContentView(scroll);
            text("기록을 켜면 이 휴대폰이 센서로 걸음을 기록해요. 앱을 닫아도 기록하며, 최근 10일 안의 기록을 조회할 수 있어요.");
            text("시작하기 전의 걸음이나 다른 건강 앱과 워치의 기록은 가져오지 않아요.");
            date("startDate", "시작 날짜"); date("endDate", "마지막 날짜");
            aggregation = new Spinner(this);
            aggregation.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, new String[]{"기간 합계", "날짜별 걸음"}));
            aggregation.setSelection("daily".equals(arguments.getString("aggregation")) ? 1 : 0); layout.addView(aggregation);
            text("걸음 기록은 이 휴대폰에서 조회해요. 음성으로 듣기를 누르면 답변에 들어간 걸음 수도 별무리 서버와 ElevenLabs로 전송돼요.");
            status = text(""); error = text(""); approve = button("조회", this::approve);
            button("걸음 기록 중지", () -> new AlertDialog.Builder(this).setMessage("기록을 중지하면 지금까지 기록한 걸음도 더 이상 조회할 수 없어요. 중지할까요?")
                .setPositiveButton("중지", (dialog, which) -> change(false)).setNegativeButton("돌아가기", null).show());
            button("앱 권한 설정", () -> startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()))));
            button("취소", () -> finishWith(null, "cancelled_by_user"));
            if (saved != null && saved.getBoolean("waitingForChange") && recording.pendingChange() != null)
                observe(recording.pendingChange(), recording.starting());
            else refresh();
        } catch (Exception failure) { StepRuntime.log(failure); finishWith(null, "invalid_arguments"); }
    }
    private TextView text(String value) { TextView view = new TextView(this); view.setText(value); layout.addView(view); return view; }
    private Button button(String label, Runnable action) {
        Button view = new Button(this); view.setText(label); view.setOnClickListener(v -> action.run()); layout.addView(view); return view;
    }
    private void date(String field, String label) throws Exception {
        Button view = button(label + ": " + arguments.getString(field), () -> {});
        view.setOnClickListener(v -> {
            LocalDate initial = LocalDate.parse(arguments.optString(field));
            new DatePickerDialog(this, (picker, year, month, day) -> {
                try { arguments.put(field, LocalDate.of(year,month+1,day).toString()); view.setText(label + ": " + arguments.getString(field)); }
                catch (Exception failure) { error.setText("날짜를 다시 골라 주세요."); }
            }, initial.getYear(),initial.getMonthValue()-1,initial.getDayOfMonth()).show();
        });
    }
    private void refresh() {
        if (status == null || completed || loading || isFinishing()) return;
        try {
            if (recording.changing()) { observe(recording.pendingChange(), recording.starting()); return; }
            Instant since = recording.recordedFrom();
            status.setText(since == null ? "아직 걸음 기록을 시작하지 않았어요." : "기록 시작: "
                + DateTimeFormatter.ofPattern("M월 d일 HH:mm").withZone(ZoneId.systemDefault()).format(since));
            approve.setText(since == null ? "기록 시작 후 조회" : "조회");
            approve.setEnabled(!permissionPending && !recording.changing());
        } catch (Exception failure) { StepRuntime.log(failure); error.setText("기록 상태를 확인하지 못했어요. 다시 열어 주세요."); approve.setEnabled(false); }
    }
    private boolean collect() {
        try {
            arguments.put("aggregation", aggregation.getSelectedItemPosition() == 1 ? "daily" : "total");
            // Validate the requested dates before permissions or recording side effects.
            LocalDate first = LocalDate.parse(arguments.getString("startDate"));
            LocalDate last = LocalDate.parse(arguments.getString("endDate"));
            if (last.isBefore(first) || last.isAfter(LocalDate.now())
                    || java.time.temporal.ChronoUnit.DAYS.between(first,last) > 30) throw new StepFailure("invalid_arguments");
            return true;
        } catch (Exception failure) { error.setText("오늘까지의 날짜로, 시작부터 마지막 날짜까지 31일 이내로 골라 주세요."); return false; }
    }
    private void approve() {
        if (completed || isFinishing() || loading || permissionPending || !collect()) return;
        int availability = recording.availability();
        if (availability != 0) {
            error.setText("Google Play 서비스를 업데이트하거나 사용 가능한지 확인해 주세요.");
            var dialog = GoogleApiAvailability.getInstance().getErrorDialog(this, availability, 62);
            if (dialog != null) dialog.show(); return;
        }
        if (!recording.hasSensor()) { error.setText("이 휴대폰에서는 걸음 센서를 사용할 수 없어요."); return; }
        if (!recording.permitted()) {
            recording.recordedFrom(); // Forget coverage after an observed permission loss.
            permissionPending = true; approve.setEnabled(false);
            requestPermissions(new String[]{Manifest.permission.ACTIVITY_RECOGNITION}, PERMISSION); return;
        }
        // Subscribe is idempotent. Each approved query re-establishes the OS contract;
        // the persisted timestamp alone is never evidence of an active registration.
        change(true);
    }
    private void change(boolean start) {
        if (loading || permissionPending || recording.changing()) return;
        loading = true; approve.setEnabled(false); error.setText(start ? "걸음 기록을 준비하고 있어요." : "걸음 기록을 중지하고 있어요.");
        StepRuntime.WORK.execute(() -> {
            try {
                CompletableFuture<Void> operation = start ? recording.start() : recording.stop();
                runOnUiThread(() -> observe(operation, start));
            } catch (Exception failure) {
                StepRuntime.log(failure);
                runOnUiThread(() -> { if (!isDestroyed() && !isFinishing()) { loading=false; error.setText("처리하지 못했어요. 다시 시도해 주세요."); refresh(); } });
            }
        });
    }
    private void observe(CompletableFuture<Void> operation, boolean start) {
        if (completed || isFinishing() || isDestroyed()) return;
        loading = true; approve.setEnabled(false);
        operation.whenComplete((ignored, failure) -> runOnUiThread(() -> {
            if (completed || isFinishing() || isDestroyed()) return;
            loading = false;
            if (failure != null) { StepRuntime.log(failure); error.setText("처리하지 못했어요. 권한과 Google Play 서비스를 확인한 뒤 다시 시도해 주세요."); refresh(); return; }
            if (start) finishWith(arguments, null);
            else { error.setText("걸음 기록을 중지했어요."); refresh(); }
        }));
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request,permissions,results);
        if (request != PERMISSION || completed || isFinishing()) return;
        permissionPending = false;
        if (!recording.permitted()) { error.setText("걸음을 기록하려면 신체 활동 권한이 필요해요. 앱 권한 설정에서 바꿀 수 있어요."); refresh(); return; }
        approve();
    }
    @Override public void onResume() { super.onResume(); refresh(); }
    private void finishWith(JSONObject result, String failure) {
        if (!completed && id != null) { completed = true; PetAIPlatformBridge.finishConfirmation(id, result, failure); }
        finish();
    }
    @Override public void onSaveInstanceState(Bundle saved) {
        if (arguments != null) {
            try { if (aggregation != null) arguments.put("aggregation", aggregation.getSelectedItemPosition() == 1 ? "daily" : "total"); }
            catch (org.json.JSONException failure) { throw new IllegalStateException(failure); }
            saved.putString("arguments", arguments.toString());
        }
        saved.putBoolean("waitingForChange", loading);
        saved.putBoolean("permissionPending",permissionPending); super.onSaveInstanceState(saved);
    }
    @Override public void onDestroy() {
        if (isFinishing() && !isChangingConfigurations() && !completed && id != null)
            PetAIPlatformBridge.finishConfirmation(id,null,"cancelled_by_user");
        super.onDestroy();
    }
}
