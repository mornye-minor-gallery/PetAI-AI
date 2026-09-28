import Foundation
import SQLite3

extension SQLiteObservationStore {
    /// Caller holds the memory-service admission gate and has drained existing writers.
    /// Delete rows, not just visibility flags: raw turns and embeddings are private data too.
    public func eraseAllMemories() throws {
        try execute("PRAGMA secure_delete = ON;")
        let tables = ["daily_diaries", "observation_embeddings", "observation_labels", "observations", "gate_results", "conversation_turns"]
        try transaction {
            for table in tables { try execute("DELETE FROM \(table);") }
            for table in tables {
                try withStatement("SELECT COUNT(*) FROM \(table);") { statement in
                    guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int64(statement, 0) == 0 else {
                        throw SQLiteObservationStoreError.statementFailed("Memory erasure was not verified")
                    }
                }
            }
        }
        // Remove WAL copies of deleted text; a busy checkpoint is a failure, not success.
        try withStatement("PRAGMA wal_checkpoint(TRUNCATE);") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 0 else {
                throw SQLiteObservationStoreError.statementFailed("Memory WAL checkpoint is busy")
            }
        }
    }
}
