import Foundation

/// App-owned storage. Model preparation and suspension must not replace this connection.
public final class MemoryDatabase: Sendable {
    private let store: SQLiteObservationStore

    public init(databaseURL: URL) {
        store = SQLiteObservationStore(databaseURL: databaseURL)
    }

    public func preparedStore() async throws -> SQLiteObservationStore {
        // initialize has no suspension inside the store actor. Concurrent callers queue
        // on the same instance; only the first successful call opens/migrates the DB.
        // A failed initialization remains an error and can be retried on this instance.
        try await store.initialize()
        return store
    }
}
