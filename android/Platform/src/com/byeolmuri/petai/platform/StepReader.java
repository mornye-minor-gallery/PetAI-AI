package com.byeolmuri.petai.platform;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicBoolean;

/** SDK-independent read lifecycle. Cancelled reads cannot publish later SDK replies. */
final class StepReader {
    interface Source {
        boolean permitted();
        CompletableFuture<Long> aggregate(Instant from, Instant to);
    }
    final CompletableFuture<List<Long>> result = new CompletableFuture<>();
    private final Source source;
    private final StepQuery query;
    private final Executor executor;
    private final List<Long> counts = new ArrayList<>();
    private final AtomicBoolean started = new AtomicBoolean();
    StepReader(Source source, StepQuery query, Executor executor) { this.source = source; this.query = query; this.executor = executor; }
    void start() { if (started.compareAndSet(false, true)) executor.execute(this::next); }
    void cancel() { result.completeExceptionally(new StepFailure("cancelled_by_user")); }
    private void next() {
        if (result.isDone()) return;
        try {
            if (!source.permitted()) throw new StepFailure("permission_denied");
            if (query.windows.isEmpty()) throw new StepFailure("data_unavailable");
            if (counts.size() == query.windows.size()) { result.complete(new ArrayList<>(counts)); return; }
            StepQuery.Window window = query.windows.get(counts.size());
            source.aggregate(window.start, window.end).whenCompleteAsync((count, error) -> {
                if (result.isDone()) return;
                if (error != null) { result.completeExceptionally(error); return; }
                if (count == null || count < 0 || count > Integer.MAX_VALUE) {
                    result.completeExceptionally(new StepFailure("native_failure")); return;
                }
                counts.add(count); next();
            }, executor);
        } catch (Exception error) { result.completeExceptionally(error); }
    }
}
