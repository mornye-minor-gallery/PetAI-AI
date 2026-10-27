package com.byeolmuri.petai.platform;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.hardware.Sensor;
import android.hardware.SensorManager;
import android.os.Build;
import android.util.AtomicFile;
import com.google.android.gms.common.ConnectionResult;
import com.google.android.gms.common.GoogleApiAvailability;
import com.google.android.gms.fitness.FitnessLocal;
import com.google.android.gms.fitness.LocalRecordingClient;
import com.google.android.gms.fitness.data.LocalDataType;
import com.google.android.gms.fitness.data.LocalField;
import com.google.android.gms.fitness.request.LocalDataReadRequest;
import java.io.*;
import java.time.Instant;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

/** Accountless Google recording only. No Health Connect, server transfer or sensor service. */
final class LocalStepRecording implements StepReader.Source {
    private final Context context;
    private final LocalRecordingClient client;
    private final AtomicFile state;
    private boolean changing;
    private CompletableFuture<Void> pendingChange;
    private boolean starting;
    LocalStepRecording(Context context) {
        this.context = context.getApplicationContext();
        client = FitnessLocal.getLocalRecordingClient(this.context);
        // A subscription belongs to this installation, never to a restored cloud backup.
        state = new AtomicFile(new File(context.getNoBackupFilesDir(), "step-recording-start"));
    }
    int availability() {
        return GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context,
            LocalRecordingClient.LOCAL_RECORDING_CLIENT_MIN_VERSION_CODE);
    }
    boolean hasSensor() {
        SensorManager manager = (SensorManager)context.getSystemService(Context.SENSOR_SERVICE);
        return manager != null && manager.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) != null;
    }
    public boolean permitted() {
        return Build.VERSION.SDK_INT < 29 || context.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) == PackageManager.PERMISSION_GRANTED;
    }
    synchronized Instant recordedFrom() {
        if (!permitted()) { write(0); return null; }
        if (!state.getBaseFile().exists()) return null;
        try (DataInputStream input = new DataInputStream(state.openRead())) {
            long millis = input.readLong();
            return millis > 0 ? Instant.ofEpochMilli(millis) : null;
        } catch (IOException error) { throw new StepFailure("native_failure"); }
    }
    synchronized boolean changing() { return changing; }
    synchronized CompletableFuture<Void> pendingChange() { return pendingChange; }
    synchronized boolean starting() { return starting; }
    synchronized CompletableFuture<Void> start() {
        if (changing) return failed("native_failure");
        if (!permitted()) return failed("permission_denied");
        if (availability() != ConnectionResult.SUCCESS || !hasSensor()) return failed("data_unavailable");
        Instant previous = recordedFrom();
        Instant since = previous == null ? Instant.now() : previous;
        // A crash before confirmation must not turn a pending registration into a successful one.
        if (previous == null) write(0);
        changing = true;
        CompletableFuture<Void> result = new CompletableFuture<>();
        pendingChange = result; starting = true;
        try { if (previous != null) {
            long now = System.currentTimeMillis();
            // Permission may have been revoked and re-granted while our process was dead.
            // A successful Task alone is insufficient: GMS can return a failed response Status.
            client.readData(new LocalDataReadRequest.Builder().aggregate(LocalDataType.TYPE_STEP_COUNT_DELTA)
                .bucketByTime(1, TimeUnit.DAYS).setTimeRange(now - 1000, now, TimeUnit.MILLISECONDS).build())
                .addOnCompleteListener(StepRuntime.WORK, task -> {
                    synchronized (this) {
                        if (!task.isSuccessful()) { changing = false; result.completeExceptionally(task.getException()); return; }
                        if (!task.getResult().getStatus().isSuccess()) {
                            changing = false;
                            try { write(0); result.completeExceptionally(new StepFailure("data_unavailable")); }
                            catch (Exception error) { result.completeExceptionally(error); }
                            return;
                        }
                        subscribe(since, result);
                    }
                });
        } else subscribe(since, result);
        } catch (Exception error) { changing = false; result.completeExceptionally(error); }
        return result;
    }
    private void subscribe(Instant since, CompletableFuture<Void> result) {
        try { client.subscribe(LocalDataType.TYPE_STEP_COUNT_DELTA).addOnCompleteListener(StepRuntime.WORK, task -> {
            synchronized (this) {
                try {
                    if (!task.isSuccessful()) throw task.getException() != null ? task.getException() : new StepFailure("native_failure");
                    if (!permitted()) throw new StepFailure("permission_denied");
                    write(since.toEpochMilli()); result.complete(null);
                } catch (Exception error) { result.completeExceptionally(error); }
                finally { changing = false; }
            }
        }); } catch (Exception error) { changing = false; result.completeExceptionally(error); }
    }
    synchronized CompletableFuture<Void> stop() {
        if (changing) return failed("native_failure");
        write(0); changing = true;
        StepRuntime.cancelAllReads();
        CompletableFuture<Void> result = new CompletableFuture<>();
        pendingChange = result; starting = false;
        try { client.unsubscribe(LocalDataType.TYPE_STEP_COUNT_DELTA).addOnCompleteListener(StepRuntime.WORK, task -> {
            synchronized (this) {
                changing = false;
                if (task.isSuccessful()) { state.delete(); result.complete(null); }
                else result.completeExceptionally(task.getException() != null ? task.getException() : new StepFailure("native_failure"));
            }
        }); } catch (Exception error) { changing = false; result.completeExceptionally(error); }
        return result;
    }
    public CompletableFuture<Long> aggregate(Instant from, Instant to) {
        if (!permitted()) return failed("permission_denied");
        if (recordedFrom() == null || changing()) return failed("data_unavailable");
        LocalDataReadRequest request = new LocalDataReadRequest.Builder()
            .aggregate(LocalDataType.TYPE_STEP_COUNT_DELTA)
            .bucketByTime(1, TimeUnit.DAYS)
            .setTimeRange(from.toEpochMilli(), to.toEpochMilli(), TimeUnit.MILLISECONDS).build();
        CompletableFuture<Long> result = new CompletableFuture<>();
        client.readData(request).addOnCompleteListener(StepRuntime.WORK, task -> {
            try {
                if (!task.isSuccessful()) throw task.getException() != null ? task.getException() : new StepFailure("native_failure");
                if (!permitted()) throw new StepFailure("permission_denied");
                if (recordedFrom() == null || changing()) throw new StepFailure("data_unavailable");
                var response = task.getResult();
                if (!response.getStatus().isSuccess()) throw new StepFailure("data_unavailable");
                long total = 0;
                for (var bucket : response.getBuckets()) for (var set : bucket.getDataSets()) for (var point : set.getDataPoints()) {
                    int steps = point.getValue(LocalField.FIELD_STEPS).asInt();
                    if (steps < 0) throw new StepFailure("native_failure");
                    total = Math.addExact(total, steps);
                }
                result.complete(total);
            } catch (Exception error) { result.completeExceptionally(error); }
        });
        return result;
    }
    private void write(long value) {
        FileOutputStream output = null;
        try {
            output = state.startWrite(); new DataOutputStream(output).writeLong(value); state.finishWrite(output);
        } catch (IOException error) { if (output != null) state.failWrite(output); throw new StepFailure("native_failure"); }
    }
    private static <T> CompletableFuture<T> failed(String code) {
        CompletableFuture<T> result = new CompletableFuture<>(); result.completeExceptionally(new StepFailure(code)); return result;
    }
}
