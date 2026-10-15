package com.byeolmuri.petai.platform;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import java.io.File;
import java.util.ArrayList;
import java.util.List;

/** User text stays in credential-protected, non-backed-up storage. Restore runs after unlock. */
final class NotificationStore extends SQLiteOpenHelper implements NotificationEngine.Store {
    NotificationStore(Context context) {
        super(context, new File(context.getNoBackupFilesDir(), "local-notifications.sqlite").getPath(), null, 1);
        setWriteAheadLoggingEnabled(true);
    }
    public void onCreate(SQLiteDatabase db) {
        String fields = "id TEXT NOT NULL, request TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, at INTEGER NOT NULL, "
            + "link TEXT NOT NULL, state TEXT NOT NULL, error TEXT";
        db.execSQL("CREATE TABLE notifications (" + fields + ", PRIMARY KEY(id))");
        db.execSQL("CREATE TABLE requests (" + fields + ", PRIMARY KEY(request))");
        db.execSQL("CREATE TABLE opened (id TEXT PRIMARY KEY, link TEXT NOT NULL)");
    }
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) { throw new IllegalStateException("Unsupported notification schema"); }
    public NotificationRecord find(String id) { return lookup("notifications", "id", id); }
    public NotificationRecord request(String id) { return lookup("requests", "request", id); }
    private NotificationRecord lookup(String table, String key, String id) {
        try (Cursor c = getReadableDatabase().query(table, null, key + "=?", new String[]{id}, null, null, null)) {
            return c.moveToFirst() ? decode(c) : null;
        }
    }
    public List<NotificationRecord> all() {
        List<NotificationRecord> result = new ArrayList<>();
        try (Cursor c = getReadableDatabase().query("notifications", null, null, null, null, null, "at ASC, id ASC")) {
            while (c.moveToNext()) result.add(decode(c));
        }
        return result;
    }
    public void save(NotificationRecord record, boolean receipt) {
        SQLiteDatabase db = getWritableDatabase(); db.beginTransaction();
        try {
            if (db.insertWithOnConflict("notifications", null, values(record), SQLiteDatabase.CONFLICT_REPLACE) < 0)
                throw new IllegalStateException("Could not persist notification reservation");
            if (receipt) db.insertOrThrow("requests", null, values(record));
            db.setTransactionSuccessful();
        } finally { db.endTransaction(); }
    }
    void opened(NotificationRecord record) {
        ContentValues values = new ContentValues(); values.put("id", record.id); values.put("link", record.deepLink);
        if (getWritableDatabase().insertWithOnConflict("opened", null, values, SQLiteDatabase.CONFLICT_REPLACE) < 0)
            throw new IllegalStateException("Could not persist notification tap");
    }
    String[] nextOpened() {
        try (Cursor c = getReadableDatabase().query("opened", null, null, null, null, null, "rowid", "1")) {
            return c.moveToFirst() ? new String[]{c.getString(c.getColumnIndexOrThrow("id")), c.getString(c.getColumnIndexOrThrow("link"))} : null;
        }
    }
    void acknowledgeOpened(String id) { getWritableDatabase().delete("opened", "id=?", new String[]{id}); }
    private static ContentValues values(NotificationRecord r) {
        ContentValues v = new ContentValues(); v.put("id", r.id); v.put("request", r.requestID); v.put("title", r.title);
        v.put("body", r.body); v.put("at", r.at); v.put("link", r.deepLink); v.put("state", r.state.name()); v.put("error", r.error); return v;
    }
    private static NotificationRecord decode(Cursor c) {
        return new NotificationRecord(text(c,"id"), text(c,"request"), text(c,"title"), text(c,"body"),
            c.getLong(c.getColumnIndexOrThrow("at")), text(c,"link"), NotificationRecord.State.valueOf(text(c,"state")), text(c,"error"));
    }
    private static String text(Cursor c, String key) { return c.getString(c.getColumnIndexOrThrow(key)); }
}
