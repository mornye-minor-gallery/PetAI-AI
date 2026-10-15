package com.byeolmuri.petai.platform;

import android.Manifest;
import android.app.Activity;
import android.app.DatePickerDialog;
import android.app.TimePickerDialog;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.text.InputFilter;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.List;
import org.json.JSONObject;

/** User confirmation and permissions only; saving remains in the tool executor. */
public final class PetAICalendarConfirmationActivity extends Activity {
    private static final int PERMISSION = 51;
    private static final DateTimeFormatter DATE_TIME = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm");
    private String id, tool;
    private JSONObject arguments;
    private LinearLayout layout;
    private EditText title, location;
    private TextView error;
    private Spinner calendars;
    private Button approve;
    private boolean completed, permissionPending, loading;
    private long selectedCalendar = -1;
    private CancellationSignal metadataRead;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        id = getIntent().getStringExtra("operationID");
        JSONObject request = id == null ? null : PetAIPlatformBridge.attach(id, this);
        if (request == null) { finish(); return; }
        try {
            tool = request.getString("tool");
            if (!CalendarRuntime.supports(tool)) throw new CalendarFailure("invalid_arguments");
            arguments = new JSONObject(saved == null ? request.getJSONObject("arguments").toString() : saved.getString("arguments"));
            permissionPending = saved != null && saved.getBoolean("permissionPending");
            selectedCalendar = saved == null ? -1 : saved.getLong("calendarID", -1);
            layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
            int padding = (int)(20 * getResources().getDisplayMetrics().density); layout.setPadding(padding, padding, padding, padding);
            ScrollView scroll = new ScrollView(this); scroll.addView(layout); setContentView(scroll);
            setTitle(creating() ? "일정을 추가할까요?" : "일정을 확인할까요?");
            if (creating()) {
                title = edit("제목", arguments.getString("title"), 120);
                location = edit("장소 (선택)", CalendarArguments.location(arguments), 200);
                if (arguments.isNull("endDateTime")) arguments.put("endDateTime",
                    LocalDateTime.parse(arguments.getString("startDateTime")).atZone(ZoneId.systemDefault()).plusHours(1).format(DATE_TIME));
                dateTime("startDateTime", "시작"); dateTime("endDateTime", "종료");
                text("저장할 캘린더"); calendars = new Spinner(this); layout.addView(calendars);
                text("계정 캘린더에 저장하면 해당 서비스로 동기화될 수 있어요.");
            } else { date("startDate", "시작 날짜"); date("endDate", "마지막 날짜"); }
            text("음성으로 듣기를 누르면 답변에 들어간 일정 내용도 별무리 서버와 ElevenLabs로 전송돼요.");
            error = new TextView(this); layout.addView(error);
            approve = button(creating() ? "추가" : "조회", this::approve);
            approve.setEnabled(!permissionPending);
            button("취소", () -> finishWith(null, "cancelled_by_user"));
            if (creating() && permitted(false)) loadCalendars();
        } catch (Exception failure) { CalendarRuntime.logFailure(failure); finishWith(null, "invalid_arguments"); }
    }
    private boolean creating() { return tool.equals("create_calendar_event"); }
    private boolean permitted(boolean writing) {
        return checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED
            && (!writing || checkSelfPermission(Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED);
    }
    private void text(String value) { TextView view = new TextView(this); view.setText(value); layout.addView(view); }
    private EditText edit(String hint, String value, int limit) {
        EditText view = new EditText(this); view.setHint(hint); view.setSingleLine(true);
        view.setFilters(new InputFilter[]{new InputFilter.LengthFilter(limit)}); view.setText(value); layout.addView(view); return view;
    }
    private Button button(String value, Runnable action) {
        Button button = new Button(this); button.setText(value); button.setOnClickListener(view -> action.run()); layout.addView(button); return button;
    }
    private void date(String field, String label) throws Exception {
        Button button = new Button(this); button.setText(label + ": " + arguments.getString(field)); layout.addView(button);
        button.setOnClickListener(view -> {
            LocalDate initial = LocalDate.parse(arguments.optString(field));
            new DatePickerDialog(this, (picker, year, month, day) -> {
                try { arguments.put(field, LocalDate.of(year, month + 1, day).toString()); button.setText(label + ": " + arguments.getString(field)); }
                catch (Exception failure) { error.setText("날짜를 다시 골라 주세요."); }
            }, initial.getYear(), initial.getMonthValue() - 1, initial.getDayOfMonth()).show();
        });
    }
    private void dateTime(String field, String label) throws Exception {
        Button day = new Button(this), time = new Button(this);
        Runnable refresh = () -> {
            LocalDateTime value = LocalDateTime.parse(arguments.optString(field));
            day.setText(label + " 날짜: " + value.toLocalDate()); time.setText(label + " 시간: " + value.toLocalTime());
        };
        day.setOnClickListener(view -> {
            LocalDateTime value = LocalDateTime.parse(arguments.optString(field));
            new DatePickerDialog(this, (picker, year, month, date) -> {
                try { arguments.put(field, LocalDateTime.of(LocalDate.of(year, month + 1, date), value.toLocalTime()).format(DATE_TIME)); refresh.run(); }
                catch (Exception failure) { error.setText("날짜를 다시 골라 주세요."); }
            }, value.getYear(), value.getMonthValue() - 1, value.getDayOfMonth()).show();
        });
        time.setOnClickListener(view -> {
            LocalDateTime value = LocalDateTime.parse(arguments.optString(field));
            new TimePickerDialog(this, (picker, hour, minute) -> {
                try { arguments.put(field, value.withHour(hour).withMinute(minute).format(DATE_TIME)); refresh.run(); }
                catch (Exception failure) { error.setText("시간을 다시 골라 주세요."); }
            }, value.getHour(), value.getMinute(), true).show();
        });
        layout.addView(day); layout.addView(time); refresh.run();
    }
    private void loadCalendars() {
        if (loading || completed || isFinishing()) return;
        loading = true; approve.setEnabled(false); metadataRead = new CancellationSignal();
        CancellationSignal signal = metadataRead;
        CalendarRuntime.WORK.execute(() -> {
            try {
                List<AndroidCalendarStore.Choice> choices = new AndroidCalendarStore(getApplicationContext(), signal).choices();
                runOnUiThread(() -> {
                    if (isDestroyed() || completed || isFinishing()) return;
                    loading = false;
                    calendars.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, choices));
                    for (int i = 0; i < choices.size(); i++) if (choices.get(i).id == selectedCalendar) calendars.setSelection(i);
                    error.setText(choices.isEmpty() ? "저장할 캘린더가 없어요. 휴대폰의 캘린더 앱에서 먼저 준비해 주세요." : "");
                    approve.setEnabled(!permissionPending && !choices.isEmpty());
                });
            } catch (Exception failure) {
                CalendarRuntime.logFailure(failure);
                runOnUiThread(() -> { if (!isDestroyed() && !completed && !isFinishing()) finishWith(null, CalendarRuntime.errorCode(failure)); });
            }
        });
    }
    private boolean collect() {
        try {
            if (creating()) {
                String name = title.getText().toString().trim();
                if (name.isEmpty()) { title.setError("제목을 적어 주세요."); return false; }
                arguments.put("title", name).put("location", location.getText().toString().trim());
                long start = LocalDateTime.parse(arguments.getString("startDateTime")).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli();
                long end = LocalDateTime.parse(arguments.getString("endDateTime")).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli();
                new CalendarEventDraft("confirmation", name, start, end, arguments.getString("location"), ZoneId.systemDefault().getId());
            } else {
                LocalDate start = LocalDate.parse(arguments.getString("startDate")), end = LocalDate.parse(arguments.getString("endDate"));
                if (end.isBefore(start) || ChronoUnit.DAYS.between(start, end) > 30) throw new IllegalArgumentException();
            }
            return true;
        } catch (Exception failure) { error.setText(creating() ? "종료 시간이 시작 시간보다 늦은지 확인해 주세요." : "시작 날짜부터 마지막 날짜까지 31일 이내로 골라 주세요."); return false; }
    }
    private void approve() {
        if (permissionPending || loading || !collect()) return;
        if (!permitted(creating())) {
            permissionPending = true; approve.setEnabled(false);
            requestPermissions(creating() ? new String[]{Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR}
                : new String[]{Manifest.permission.READ_CALENDAR}, PERMISSION);
            return;
        }
        if (creating()) {
            Object selection = calendars.getSelectedItem();
            if (!(selection instanceof AndroidCalendarStore.Choice)) { loadCalendars(); return; }
            try { arguments.put("calendarID", ((AndroidCalendarStore.Choice)selection).id); }
            catch (Exception failure) { finishWith(null, "invalid_arguments"); return; }
        }
        finishWith(arguments, null);
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request != PERMISSION) return;
        permissionPending = false;
        if (!permitted(creating())) { finishWith(null, "permission_denied"); return; }
        if (creating()) loadCalendars(); // Show the actual destination before approving a write.
        else finishWith(arguments, null);
    }
    private void finishWith(JSONObject result, String failure) {
        if (!completed && id != null) { completed = true; PetAIPlatformBridge.finishConfirmation(id, result, failure); }
        finish();
    }
    @Override public void onSaveInstanceState(Bundle saved) {
        if (arguments != null) { collect(); saved.putString("arguments", arguments.toString()); }
        Object selection = calendars == null ? null : calendars.getSelectedItem();
        saved.putLong("calendarID", selection instanceof AndroidCalendarStore.Choice ? ((AndroidCalendarStore.Choice)selection).id : selectedCalendar);
        saved.putBoolean("permissionPending", permissionPending); super.onSaveInstanceState(saved);
    }
    @Override public void onDestroy() {
        if (metadataRead != null) metadataRead.cancel();
        if (isFinishing() && !isChangingConfigurations() && !completed && id != null)
            PetAIPlatformBridge.finishConfirmation(id, null, "cancelled_by_user");
        super.onDestroy();
    }
}
