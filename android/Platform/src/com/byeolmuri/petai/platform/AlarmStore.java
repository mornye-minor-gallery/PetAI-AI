package com.byeolmuri.petai.platform;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.os.UserManager;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** Minimal reboot-safe metadata and separately credential-protected user labels. */
final class AlarmStore extends SQLiteOpenHelper implements AlarmEngine.Store {
    private final Context credentialContext;
    AlarmStore(Context context) {
        super(context.createDeviceProtectedStorageContext(), new File(
            context.createDeviceProtectedStorageContext().getNoBackupFilesDir(), "owned-alarms.sqlite").getPath(), null, 1);
        credentialContext = context.getApplicationContext();
        setWriteAheadLoggingEnabled(true);
    }
    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE alarms (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, kind TEXT NOT NULL, "
            + "wall INTEGER NOT NULL, elapsed INTEGER NOT NULL, boot INTEGER NOT NULL, duration INTEGER NOT NULL, "
            + "state TEXT NOT NULL, error TEXT)");
        db.execSQL("CREATE INDEX alarms_state_time ON alarms(state, wall)");
    }
    @Override public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        throw new IllegalStateException("Unsupported alarm schema upgrade");
    }
    @Override public AlarmRecord find(String id) {
        if (id == null) return null;
        try (Cursor cursor = getReadableDatabase().query("alarms", null, "id=?", new String[]{id}, null, null, null)) {
            return cursor.moveToFirst() ? decode(cursor) : null;
        }
    }
    @Override public List<AlarmRecord> active() {
        List<AlarmRecord> result = new ArrayList<>();
        try (Cursor cursor = getReadableDatabase().query("alarms", null,
                "state IN ('REGISTERING','SCHEDULED','RINGING','BLOCKED')", null, null, null, "wall ASC, id ASC")) {
            while (cursor.moveToNext()) result.add(decode(cursor));
        }
        return result;
    }
    @Override public void insert(AlarmRecord record, String label) {
        writeLabel(record.id, label);
        getWritableDatabase().insertOrThrow("alarms", null, values(record));
    }
    @Override public boolean replace(AlarmRecord record, AlarmRecord.State expected) {
        return getWritableDatabase().update("alarms", values(record), "id=? AND state=?",
            new String[]{record.id, expected.name()}) == 1;
    }
    String label(AlarmRecord record) {
        // Credential storage is unavailable only before the first unlock after boot.
        // Use a generic presentation then; private labels are never put in Direct Boot storage.
        UserManager user = credentialContext.getSystemService(UserManager.class);
        if (user != null && !user.isUserUnlocked()) return record.kind.equals("timer") ? "타이머" : "알람";
        try {
            return new String(labelFile(record.id).readFully(), StandardCharsets.UTF_8);
        } catch (IOException error) { throw new IllegalStateException("Alarm label could not be read", error); }
    }
    private AtomicFile labelFile(String id) {
        UUID.fromString(id);
        File directory = new File(credentialContext.getNoBackupFilesDir(), "AlarmLabels");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException("Alarm label directory unavailable");
        return new AtomicFile(new File(directory, id));
    }
    private void writeLabel(String id, String label) {
        AtomicFile file = labelFile(id);
        FileOutputStream stream = null;
        try {
            byte[] bytes = label.getBytes(StandardCharsets.UTF_8);
            stream = file.startWrite(); stream.write(bytes); stream.getFD().sync(); file.finishWrite(stream);
            if (!java.util.Arrays.equals(bytes, file.readFully())) throw new IOException("Alarm label verification failed");
        } catch (IOException error) {
            file.failWrite(stream);
            throw new IllegalStateException("Alarm label could not be saved", error);
        }
    }
    private static ContentValues values(AlarmRecord record) {
        ContentValues values = new ContentValues();
        values.put("id", record.id); values.put("fingerprint", record.fingerprint); values.put("kind", record.kind);
        values.put("wall", record.wallMillis); values.put("elapsed", record.elapsedDeadline);
        values.put("boot", record.bootCount); values.put("duration", record.durationSeconds);
        values.put("state", record.state.name()); values.put("error", record.errorCode);
        return values;
    }
    private static AlarmRecord decode(Cursor cursor) {
        return new AlarmRecord(cursor.getString(cursor.getColumnIndexOrThrow("id")),
            cursor.getString(cursor.getColumnIndexOrThrow("fingerprint")), cursor.getString(cursor.getColumnIndexOrThrow("kind")),
            cursor.getLong(cursor.getColumnIndexOrThrow("wall")), cursor.getLong(cursor.getColumnIndexOrThrow("elapsed")),
            cursor.getInt(cursor.getColumnIndexOrThrow("boot")), cursor.getInt(cursor.getColumnIndexOrThrow("duration")),
            AlarmRecord.State.valueOf(cursor.getString(cursor.getColumnIndexOrThrow("state"))),
            cursor.getString(cursor.getColumnIndexOrThrow("error")));
    }
}
