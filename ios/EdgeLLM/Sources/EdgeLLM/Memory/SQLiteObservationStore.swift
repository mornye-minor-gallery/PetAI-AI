#if os(Android)
import Crypto
#else
import CryptoKit
#endif
import Foundation
import SQLite3

public enum SQLiteObservationStoreError:
    Error,
    Equatable,
    Sendable
{
    case databaseNotInitialized
    case openFailed(String)
    case statementFailed(String)
    case unsupportedSchemaVersion(found: Int, expected: Int)
    case invalidStoredValue(column: String)
    case invalidEmbedding(String)
    case unknownObservation(String)
    case rollbackFailed(operation: String, rollback: String)
}

extension SQLiteObservationStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            "EdgeMem SQLite database is not initialized."
        case .openFailed(let message):
            "Could not open the EdgeMem SQLite database: \(message)"
        case .statementFailed(let message):
            "EdgeMem SQLite statement failed: \(message)"
        case .unsupportedSchemaVersion(let found, let expected):
            "Unsupported EdgeMem schema version \(found); expected \(expected)."
        case .invalidStoredValue(let column):
            "EdgeMem SQLite contains an invalid value for \(column)."
        case .invalidEmbedding(let message):
            "EdgeMem cannot store this embedding: \(message)"
        case let .rollbackFailed(operation, rollback):
            "Memory write failed (\(operation)); rollback failed (\(rollback)). The connection was closed."
        case .unknownObservation(let observationID):
            "EdgeMem observation does not exist or is inactive: \(observationID)"
        }
    }
}

public actor SQLiteObservationStore:
    MemoryObservationStoring,
    MemoryEmbeddingCandidateLoading
{
    public nonisolated let securityPolicy: MemoryStoreSecurityPolicy =
        .appPrivatePrototype

    public nonisolated let databaseURL: URL

    private let connection = SQLiteConnection()
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }()

    public init() throws {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        databaseURL = applicationSupport
            .appendingPathComponent("EdgeLLM", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
            .appendingPathComponent("edgemem.sqlite3", isDirectory: false)
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public nonisolated static func removeDatabase(at url: URL) throws {
        let manager = FileManager.default
        for path in [
            url.path,
            url.path + "-wal",
            url.path + "-shm",
            url.path + "-journal",
        ] where manager.fileExists(atPath: path) {
            try manager.removeItem(atPath: path)
        }
    }

    public func initialize() async throws {
        guard connection.handle == nil else {
            return
        }

        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try excludeFromCloudBackup(directory)

        try openDatabase()
        if try isLegacyPrototypeDatabase() {
            closeDatabase()
            try Self.removeDatabase(at: databaseURL)
            try openDatabase()
        }

        do {
            try execute("PRAGMA foreign_keys = ON;")
            try execute("PRAGMA journal_mode = WAL;")
            try execute(EdgeMemSQLiteSchema.statements[1])

            if let existingVersion = try existingSchemaVersion(),
                existingVersion != EdgeMemSQLiteSchema.version
            {
                if existingVersion == 1 {
                    try transaction {
                        for statement in
                            EdgeMemSQLiteSchema.migrateVersion1ToVersion2
                        {
                            try execute(statement)
                        }
                    }
                    try transaction {
                        for statement in EdgeMemSQLiteSchema
                            .resetVersion2ForCharacterNeutralVersion3
                        {
                            try execute(statement)
                        }
                    }
                } else if existingVersion == 2 {
                    try transaction {
                        for statement in EdgeMemSQLiteSchema
                            .resetVersion2ForCharacterNeutralVersion3
                        {
                            try execute(statement)
                        }
                    }
                } else if existingVersion != 3 {
                    throw SQLiteObservationStoreError
                        .unsupportedSchemaVersion(
                            found: existingVersion,
                            expected: EdgeMemSQLiteSchema.version
                        )
                }
            }

            try transaction {
                for statement in EdgeMemSQLiteSchema.statements.dropFirst(2) {
                    try execute(statement)
                }
                try execute(
                    """
                    INSERT OR REPLACE INTO schema_metadata(key, value)
                    VALUES ('schema_version', '\(EdgeMemSQLiteSchema.version)');
                    """
                )
            }
        } catch {
            closeDatabase()
            throw error
        }
    }



    public func activeObservations(
        in scope: MemoryScope
    ) async throws -> [MemoryObservation] {
        let rows = try observationRows(
            sql:
                """
                SELECT
                    o.id,
                    o.turn_id,
                    t.session_id,
                    t.sequence,
                    t.user_id,
                    t.character_id,
                    t.occurred_at,
                    t.text,
                    o.state,
                    o.created_at
                FROM observations AS o
                INNER JOIN conversation_turns AS t
                    ON t.id = o.turn_id
                WHERE t.user_id = ?
                  AND t.character_id = ?
                  AND o.state = 'active'
                ORDER BY t.occurred_at DESC, o.id ASC;
                """,
            scope: scope
        )
        return try rows.map(makeObservation)
    }

    public func activeObservations(
        in scope: MemoryScope, from start: Date, to end: Date
    ) throws -> [MemoryObservation] {
        guard start < end else { return [] }
        let rows = try withStatement(
            """
            SELECT o.id, o.turn_id, t.session_id, t.sequence, t.user_id,
                   t.character_id, t.occurred_at, t.text, o.state, o.created_at
            FROM observations AS o
            INNER JOIN conversation_turns AS t ON t.id = o.turn_id
            WHERE t.user_id = ? AND t.character_id = ? AND o.state = 'active'
              AND t.occurred_at >= ? AND t.occurred_at < ?
            ORDER BY t.occurred_at ASC, o.id ASC;
            """
        ) { statement in
            try bind(scope.userID, at: 1, to: statement)
            try bind(scope.characterID, at: 2, to: statement)
            try bind(dateString(start), at: 3, to: statement)
            try bind(dateString(end), at: 4, to: statement)
            var rows: [ObservationRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw statementError() }
                rows.append(try observationRow(from: statement))
            }
            return rows
        }
        return try rows.map(makeObservation)
    }

    /// Export reads only complete active observations, across every device-local scope.
    /// Orphan conversation/gate rows from an interrupted write are not observations.
    public func allActiveObservations() async throws -> [MemoryObservation] {
        let rows = try withStatement(
            """
            SELECT
                o.id, o.turn_id, t.session_id, t.sequence, t.user_id,
                t.character_id, t.occurred_at, t.text, o.state, o.created_at
            FROM observations AS o
            INNER JOIN conversation_turns AS t ON t.id = o.turn_id
            WHERE o.state = 'active'
            ORDER BY t.occurred_at DESC, o.id ASC;
            """
        ) { statement in
            var rows: [ObservationRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw statementError() }
                rows.append(try observationRow(from: statement))
            }
            return rows
        }
        return try rows.map(makeObservation)
    }

    public func embeddingCandidates(
        in scope: MemoryScope,
        modelID: String
    ) async throws -> [MemoryEmbeddingCandidate] {
        let rows = try withStatement(
            """
            SELECT
                o.id,
                o.turn_id,
                t.session_id,
                t.sequence,
                t.user_id,
                t.character_id,
                t.occurred_at,
                t.text,
                o.state,
                o.created_at,
                e.model_id,
                e.dimension,
                e.vector,
                e.created_at
            FROM observations AS o
            INNER JOIN conversation_turns AS t
                ON t.id = o.turn_id
            INNER JOIN observation_embeddings AS e
                ON e.observation_id = o.id
            WHERE t.user_id = ?
              AND t.character_id = ?
              AND o.state = 'active'
              AND e.model_id = ?
            ORDER BY t.occurred_at DESC, o.id ASC;
            """
        ) { statement in
            try bind(scope.userID, at: 1, to: statement)
            try bind(scope.characterID, at: 2, to: statement)
            try bind(modelID, at: 3, to: statement)

            var rows: [(ObservationRow, MemoryObservationEmbedding)] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    break
                }
                guard result == SQLITE_ROW else {
                    throw statementError()
                }
                let row = try observationRow(from: statement)
                let dimension = try positiveInteger(
                    at: 11,
                    from: statement,
                    column: "dimension"
                )
                rows.append(
                    (
                        row,
                        MemoryObservationEmbedding(
                            observationID: row.observationID,
                            modelID: try text(
                                at: 10,
                                from: statement,
                                column: "model_id"
                            ),
                            vector: try vector(
                                at: 12,
                                dimension: dimension,
                                from: statement
                            ),
                            createdAt: try date(
                                at: 13,
                                from: statement,
                                column: "embedding_created_at"
                            )
                        )
                    )
                )
            }
            return rows
        }

        return try rows.map { row, embedding in
            MemoryEmbeddingCandidate(
                observation: try makeObservation(row),
                embedding: embedding
            )
        }
    }

    public func markDeleted(
        observationID: String,
        in scope: MemoryScope
    ) async throws {
        try transaction {
            try withStatement(
                """
                UPDATE observations
                SET state = 'deleted'
                WHERE id = ?
                  AND state = 'active'
                  AND turn_id IN (
                      SELECT id
                      FROM conversation_turns
                      WHERE user_id = ?
                        AND character_id = ?
                  );
                """
            ) { statement in
                try bind(observationID, at: 1, to: statement)
                try bind(scope.userID, at: 2, to: statement)
                try bind(scope.characterID, at: 3, to: statement)
                try stepExpectingDone(statement)
            }

            guard sqlite3_changes(try databaseHandle()) == 1 else {
                throw SQLiteObservationStoreError.unknownObservation(
                    observationID
                )
            }

            try withStatement(
                """
                DELETE FROM observation_embeddings
                WHERE observation_id = ?;
                """
            ) { statement in
                try bind(observationID, at: 1, to: statement)
                try stepExpectingDone(statement)
            }
        }
    }

    public func close() async {
        closeDatabase()
    }

    private func openDatabase() throws {
        var openedDatabase: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "unknown SQLite open error"
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw SQLiteObservationStoreError.openFailed(message)
        }
        connection.handle = openedDatabase
    }

    private func closeDatabase() {
        guard let database = connection.handle else {
            return
        }
        sqlite3_close_v2(database)
        connection.handle = nil
    }

    private func isLegacyPrototypeDatabase() throws -> Bool {
        try tableExists("memory_observations")
            && !tableExists("conversation_turns")
    }

    private func tableExists(_ name: String) throws -> Bool {
        try withStatement(
            """
            SELECT 1
            FROM sqlite_master
            WHERE type = 'table'
              AND name = ?;
            """
        ) { statement in
            try bind(name, at: 1, to: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW || result == SQLITE_DONE else {
                throw statementError()
            }
            return result == SQLITE_ROW
        }
    }

    private func existingSchemaVersion() throws -> Int? {
        try withStatement(
            """
            SELECT value
            FROM schema_metadata
            WHERE key = 'schema_version';
            """
        ) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return nil
            }
            guard result == SQLITE_ROW else {
                throw statementError()
            }
            let stored = try text(
                at: 0,
                from: statement,
                column: "schema_version"
            )
            guard let version = Int(stored) else {
                throw SQLiteObservationStoreError.invalidStoredValue(
                    column: "schema_version"
                )
            }
            return version
        }
    }

    func nextSequence(in sessionID: String) throws -> Int {
        try withStatement(
            """
            SELECT COALESCE(MAX(sequence), -1) + 1
            FROM conversation_turns
            WHERE session_id = ?;
            """
        ) { statement in
            try bind(sessionID, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw statementError()
            }
            let value = sqlite3_column_int64(statement, 0)
            guard let sequence = Int(exactly: value), sequence >= 0 else {
                throw SQLiteObservationStoreError.invalidStoredValue(
                    column: "sequence"
                )
            }
            return sequence
        }
    }

    private func observationRows(
        sql: String,
        scope: MemoryScope
    ) throws -> [ObservationRow] {
        try withStatement(sql) { statement in
            try bind(scope.userID, at: 1, to: statement)
            try bind(scope.characterID, at: 2, to: statement)

            var rows: [ObservationRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    break
                }
                guard result == SQLITE_ROW else {
                    throw statementError()
                }
                rows.append(try observationRow(from: statement))
            }
            return rows
        }
    }

    private func observationRow(
        from statement: OpaquePointer
    ) throws -> ObservationRow {
        let stateValue = try text(
            at: 8,
            from: statement,
            column: "state"
        )
        guard let state = MemoryObservationState(rawValue: stateValue) else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: "state"
            )
        }
        return ObservationRow(
            observationID: try text(
                at: 0,
                from: statement,
                column: "observation_id"
            ),
            turnID: try text(
                at: 1,
                from: statement,
                column: "turn_id"
            ),
            sessionID: try text(
                at: 2,
                from: statement,
                column: "session_id"
            ),
            sequence: try nonnegativeInteger(
                at: 3,
                from: statement,
                column: "sequence"
            ),
            userID: try text(
                at: 4,
                from: statement,
                column: "user_id"
            ),
            characterID: try text(
                at: 5,
                from: statement,
                column: "character_id"
            ),
            occurredAt: try date(
                at: 6,
                from: statement,
                column: "occurred_at"
            ),
            rawText: try text(
                at: 7,
                from: statement,
                column: "text"
            ),
            state: state,
            createdAt: try date(
                at: 9,
                from: statement,
                column: "created_at"
            )
        )
    }

    private func makeObservation(
        _ row: ObservationRow
    ) throws -> MemoryObservation {
        MemoryObservation(
            id: row.observationID,
            turnID: row.turnID,
            sessionID: row.sessionID,
            sequence: row.sequence,
            scope: MemoryScope(
                userID: row.userID,
                characterID: row.characterID
            ),
            occurredAt: row.occurredAt,
            rawText: row.rawText,
            labelEvidence: try labelEvidence(
                forObservationID: row.observationID
            ),
            state: row.state,
            createdAt: row.createdAt
        )
    }

    private func labelEvidence(
        forObservationID observationID: String
    ) throws -> [MemoryLabelEvidence] {
        try withStatement(
            """
            SELECT label, score, source, classifier_version
            FROM observation_labels
            WHERE observation_id = ?
            ORDER BY label ASC;
            """
        ) { statement in
            try bind(observationID, at: 1, to: statement)

            var evidence: [MemoryLabelEvidence] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    break
                }
                guard result == SQLITE_ROW else {
                    throw statementError()
                }
                let labelValue = try text(
                    at: 0,
                    from: statement,
                    column: "label"
                )
                let sourceValue = try text(
                    at: 2,
                    from: statement,
                    column: "source"
                )
                guard
                    let label = MemoryLabel(rawValue: labelValue),
                    let source = MemoryLabelSource(rawValue: sourceValue)
                else {
                    throw SQLiteObservationStoreError.invalidStoredValue(
                        column: "observation_labels"
                    )
                }
                evidence.append(
                    MemoryLabelEvidence(
                        label: label,
                        score: optionalFloat(
                            at: 1,
                            from: statement
                        ),
                        source: source,
                        classifierVersion: try text(
                            at: 3,
                            from: statement,
                            column: "classifier_version"
                        )
                    )
                )
            }
            return evidence
        }
    }

    func validate(
        _ embedding: MemoryObservationEmbedding,
        for observation: MemoryObservation
    ) throws {
        guard embedding.observationID == observation.id else {
            throw SQLiteObservationStoreError.invalidEmbedding(
                "observation IDs do not match"
            )
        }
        guard
            !embedding.modelID.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            throw SQLiteObservationStoreError.invalidEmbedding(
                "model ID is empty"
            )
        }
        guard !embedding.vector.isEmpty else {
            throw SQLiteObservationStoreError.invalidEmbedding(
                "vector is empty"
            )
        }
        if let index = embedding.vector.firstIndex(where: { !$0.isFinite }) {
            throw SQLiteObservationStoreError.invalidEmbedding(
                "vector contains a non-finite value at index \(index)"
            )
        }
    }

    func execute(_ sql: String) throws {
        let database = try databaseHandle()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(
            database,
            sql,
            nil,
            nil,
            &errorPointer
        )
        guard result == SQLITE_OK else {
            let message = errorPointer.map {
                String(cString: $0)
            } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw SQLiteObservationStoreError.statementFailed(message)
        }
    }

    func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            let operationError = error
            // SQLite may already have rolled back after an I/O error or RAISE(ROLLBACK).
            if let database = connection.handle, sqlite3_get_autocommit(database) == 0 {
                do {
                    try execute("ROLLBACK;")
                } catch {
                    closeDatabase()
                    throw SQLiteObservationStoreError.rollbackFailed(
                        operation: String(describing: operationError),
                        rollback: String(describing: error))
                }
            }
            throw operationError
        }
    }

    func withStatement<Result>(
        _ sql: String,
        body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        let database = try databaseHandle()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        )
        guard result == SQLITE_OK, let statement else {
            throw statementError()
        }
        defer {
            sqlite3_finalize(statement)
        }
        return try body(statement)
    }

    func bind(
        _ value: String,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let result = value.withCString {
            sqlite3_bind_text(
                statement,
                index,
                $0,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard result == SQLITE_OK else {
            throw statementError()
        }
    }

    func bind(
        _ value: String?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw statementError()
            }
            return
        }
        try bind(value, at: index, to: statement)
    }

    func bind(
        _ value: Int,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        guard
            sqlite3_bind_int64(statement, index, sqlite3_int64(value))
                == SQLITE_OK
        else {
            throw statementError()
        }
    }

    func bind(
        _ value: Bool,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        try bind(value ? 1 : 0, at: index, to: statement)
    }

    func bind(
        _ value: Float,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        guard sqlite3_bind_double(statement, index, Double(value)) == SQLITE_OK
        else {
            throw statementError()
        }
    }

    func bind(
        _ value: Float?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw statementError()
            }
            return
        }
        try bind(value, at: index, to: statement)
    }

    func bind(
        _ value: Data,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard result == SQLITE_OK else {
            throw statementError()
        }
    }

    func stepExpectingDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw statementError()
        }
    }

    func text(
        at index: Int32,
        from statement: OpaquePointer,
        column: String
    ) throws -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: column
            )
        }
        return String(cString: value)
    }

    private func nonnegativeInteger(
        at index: Int32,
        from statement: OpaquePointer,
        column: String
    ) throws -> Int {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: column
            )
        }
        let value = sqlite3_column_int64(statement, index)
        guard let integer = Int(exactly: value), integer >= 0 else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: column
            )
        }
        return integer
    }

    private func positiveInteger(
        at index: Int32,
        from statement: OpaquePointer,
        column: String
    ) throws -> Int {
        let integer = try nonnegativeInteger(
            at: index,
            from: statement,
            column: column
        )
        guard integer > 0 else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: column
            )
        }
        return integer
    }

    private func optionalFloat(
        at index: Int32,
        from statement: OpaquePointer
    ) -> Float? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Float(sqlite3_column_double(statement, index))
    }

    private func vector(
        at index: Int32,
        dimension: Int,
        from statement: OpaquePointer
    ) throws -> [Float] {
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        let expectedByteCount = dimension * MemoryLayout<UInt32>.size
        guard
            byteCount == expectedByteCount,
            let bytes = sqlite3_column_blob(statement, index)
        else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: "vector"
            )
        }

        let data = Data(bytes: bytes, count: byteCount)
        let vector: [Float] = data.withUnsafeBytes { buffer in
            (0..<dimension).map { vectorIndex in
                let bits = buffer.loadUnaligned(
                    fromByteOffset:
                        vectorIndex * MemoryLayout<UInt32>.size,
                    as: UInt32.self
                )
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: "vector"
            )
        }
        return vector
    }

    private func date(
        at index: Int32,
        from statement: OpaquePointer,
        column: String
    ) throws -> Date {
        let storedValue = try text(
            at: index,
            from: statement,
            column: column
        )
        guard let date = dateFormatter.date(from: storedValue) else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: column
            )
        }
        return date
    }

    func dateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    func vectorData(_ vector: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(vector.count * MemoryLayout<UInt32>.size)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    private func databaseHandle() throws -> OpaquePointer {
        guard let database = connection.handle else {
            throw SQLiteObservationStoreError.databaseNotInitialized
        }
        return database
    }

    func statementError() -> SQLiteObservationStoreError {
        guard let database = connection.handle else {
            return .databaseNotInitialized
        }
        return .statementFailed(String(cString: sqlite3_errmsg(database)))
    }

    private func excludeFromCloudBackup(_ directory: URL) throws {
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    var handle: OpaquePointer?

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }
}

private struct ObservationRow {
    let observationID: String
    let turnID: String
    let sessionID: String
    let sequence: Int
    let userID: String
    let characterID: String
    let occurredAt: Date
    let rawText: String
    let state: MemoryObservationState
    let createdAt: Date
}
