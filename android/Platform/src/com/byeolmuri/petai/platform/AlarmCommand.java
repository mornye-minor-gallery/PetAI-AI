package com.byeolmuri.petai.platform;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.UUID;

public final class AlarmCommand {
    public final String requestID, kind, label;
    public final long wallMillis;
    public final int durationSeconds;

    private AlarmCommand(String requestID, String kind, long wallMillis, int durationSeconds, String label) {
        this.requestID = requestID; this.kind = kind; this.wallMillis = wallMillis;
        this.durationSeconds = durationSeconds; this.label = label == null ? "" : label.trim();
    }
    public static AlarmCommand alarm(String requestID, long wallMillis, String label) {
        return new AlarmCommand(requestID, "alarm", wallMillis, 0, label);
    }
    public static AlarmCommand timer(String requestID, int durationSeconds, String label) {
        return new AlarmCommand(requestID, "timer", 0, durationSeconds, label);
    }
    void validate() throws AlarmFailure {
        if (requestID == null || requestID.trim().isEmpty() || requestID.length() > 128
                || label.isEmpty() || label.codePointCount(0, label.length()) > 80) {
            throw new AlarmFailure("invalid_arguments");
        }
        if (kind.equals("timer") && (durationSeconds < 1 || durationSeconds > 86_400)) {
            throw new AlarmFailure("unsupported_range");
        }
    }
    String id() {
        return UUID.nameUUIDFromBytes(("PetAIAlarm:" + requestID).getBytes(StandardCharsets.UTF_8)).toString();
    }
    String fingerprint() {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(
                (kind + "\n" + wallMillis + "\n" + durationSeconds + "\n" + label).getBytes(StandardCharsets.UTF_8));
            StringBuilder result = new StringBuilder();
            for (byte value : digest) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
            return result.toString();
        } catch (NoSuchAlgorithmException error) { throw new IllegalStateException(error); }
    }
}
