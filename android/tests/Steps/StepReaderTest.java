package com.byeolmuri.petai.platform;
import java.time.Instant;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;

public final class StepReaderTest {
    static final class Source implements StepReader.Source {
        boolean permission = true;
        int calls;
        CompletableFuture<Long> pending = new CompletableFuture<>();
        public boolean permitted() { return permission; }
        public CompletableFuture<Long> aggregate(Instant a, Instant b) { calls++; return pending; }
    }
    static StepReader reader(Source source) {
        return new StepReader(source, new StepQuery("2026-10-15", "2026-10-15", "total", "UTC",
            Instant.parse("2026-10-15T12:00:00Z"), Instant.parse("2026-10-14T12:00:00Z")), Runnable::run);
    }
    static void failed(StepReader reader, String code) {
        try { reader.result.join(); throw new AssertionError("expected failure"); }
        catch (CompletionException e) { StepQueryTest.check(((StepFailure)e.getCause()).code.equals(code)); }
    }
    public static void main(String[] args) {
        Source source = new Source(); StepReader read = reader(source); read.start(); source.pending.complete(0L);
        read.start(); StepQueryTest.check(source.calls == 1);
        StepQueryTest.check(read.result.join().get(0) == 0); // A successful empty SDK aggregate is recorded zero.
        source = new Source(); read = reader(source); read.cancel(); read.start(); failed(read,"cancelled_by_user");
        StepQueryTest.check(source.calls == 0);
        source = new Source(); read = reader(source); read.start(); read.cancel(); source.pending.complete(50L); failed(read,"cancelled_by_user");
        source = new Source(); read = reader(source); read.start(); source.permission = false; source.pending.complete(50L); failed(read,"permission_denied");
        source = new Source(); source.permission = false; read = reader(source); read.start(); failed(read,"permission_denied");
        source = new Source(); read = reader(source); read.start(); source.pending.complete(-1L); failed(read,"native_failure");
        source = new Source(); read = reader(source); read.start(); source.pending.completeExceptionally(new StepFailure("data_unavailable")); failed(read,"data_unavailable");
        System.out.println("StepReader: " + StepQueryTest.checks + " checks passed");
    }
}
