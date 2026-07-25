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
    case unknownObservation(String)
}

extension SQLiteObservationStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            "EdgeMem SQLite database is not initialized."
        case let .openFailed(message):
            "Could not open the EdgeMem SQLite database: \(message)"
        case let .statementFailed(message):
            "EdgeMem SQLite statement failed: \(message)"
        case let .unsupportedSchemaVersion(found, expected):
            "Unsupported EdgeMem schema version \(found); expected \(expected)."
        case let .invalidStoredValue(column):
            "EdgeMem SQLite contains an invalid value for \(column)."
        case let .unknownObservation(observationID):
            "EdgeMem observation does not exist or is inactive: \(observationID)"
        }
    }
}

public actor SQLiteObservationStore: MemoryObservationStoring {
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

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
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

        var openedDatabase: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "unknown SQLite open error"
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw SQLiteObservationStoreError.openFailed(message)
        }

        connection.handle = openedDatabase
        do {
            try execute("PRAGMA journal_mode = WAL;")
            try execute(EdgeMemSQLiteSchema.statements[0])
            try execute(EdgeMemSQLiteSchema.statements[1])

            if let existingVersion = try existingSchemaVersion(),
               existingVersion != EdgeMemSQLiteSchema.version {
                throw SQLiteObservationStoreError.unsupportedSchemaVersion(
                    found: existingVersion,
                    expected: EdgeMemSQLiteSchema.version
                )
            }

            try transaction {
                for statement in EdgeMemSQLiteSchema.statements.dropFirst(2) {
                    try execute(statement)
                }
                try execute(
                    """
                    INSERT OR IGNORE INTO schema_metadata(key, value)
                    VALUES ('schema_version', '\(EdgeMemSQLiteSchema.version)');
                    """
                )
            }
        } catch {
            sqlite3_close_v2(openedDatabase)
            connection.handle = nil
            throw error
        }
    }

    public func save(_ observation: MemoryObservation) async throws {
        guard !observation.labels.isEmpty else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: "labels"
            )
        }

        try transaction {
            try withStatement(
                """
                INSERT INTO memory_observations(
                    observation_id,
                    source_message_id,
                    session_id,
                    user_id,
                    character_id,
                    occurred_at,
                    raw_text,
                    state,
                    valid_from,
                    valid_until,
                    supersedes_observation_id,
                    created_at,
                    updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            ) { statement in
                try bind(observation.id, at: 1, to: statement)
                try bind(observation.sourceMessageID, at: 2, to: statement)
                try bind(observation.sessionID, at: 3, to: statement)
                try bind(observation.scope.userID, at: 4, to: statement)
                try bind(observation.scope.characterID, at: 5, to: statement)
                try bind(dateString(observation.occurredAt), at: 6, to: statement)
                try bind(observation.rawText, at: 7, to: statement)
                try bind(observation.state.rawValue, at: 8, to: statement)
                try bind(
                    observation.validFrom.map(dateString),
                    at: 9,
                    to: statement
                )
                try bind(
                    observation.validUntil.map(dateString),
                    at: 10,
                    to: statement
                )
                try bind(
                    observation.supersedesObservationID,
                    at: 11,
                    to: statement
                )
                try bind(dateString(observation.createdAt), at: 12, to: statement)
                try bind(dateString(observation.updatedAt), at: 13, to: statement)
                try stepExpectingDone(statement)
            }

            for label in observation.labels {
                try withStatement(
                    """
                    INSERT INTO memory_observation_labels(
                        observation_id,
                        label,
                        classifier_version,
                        created_at
                    ) VALUES (?, ?, ?, ?);
                    """
                ) { statement in
                    try bind(observation.id, at: 1, to: statement)
                    try bind(label.rawValue, at: 2, to: statement)
                    try bind(
                        observation.classifierVersion,
                        at: 3,
                        to: statement
                    )
                    try bind(
                        dateString(observation.createdAt),
                        at: 4,
                        to: statement
                    )
                    try stepExpectingDone(statement)
                }
            }
        }
    }

    public func activeObservations(
        in scope: MemoryScope
    ) async throws -> [MemoryObservation] {
        let rows = try withStatement(
            """
            SELECT
                observation_id,
                source_message_id,
                session_id,
                user_id,
                character_id,
                occurred_at,
                raw_text,
                state,
                valid_from,
                valid_until,
                supersedes_observation_id,
                created_at,
                updated_at
            FROM memory_observations
            WHERE user_id = ?
              AND character_id = ?
              AND state = 'active'
            ORDER BY occurred_at DESC, observation_id ASC;
            """
        ) { statement in
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

        var observations: [MemoryObservation] = []
        observations.reserveCapacity(rows.count)
        for row in rows {
            let classification = try labels(
                forObservationID: row.observationID
            )
            observations.append(
                MemoryObservation(
                    id: row.observationID,
                    sourceMessageID: row.sourceMessageID,
                    sessionID: row.sessionID,
                    scope: MemoryScope(
                        userID: row.userID,
                        characterID: row.characterID
                    ),
                    occurredAt: row.occurredAt,
                    rawText: row.rawText,
                    labels: classification.labels,
                    classifierVersion: classification.version,
                    state: row.state,
                    validFrom: row.validFrom,
                    validUntil: row.validUntil,
                    supersedesObservationID: row.supersedesObservationID,
                    createdAt: row.createdAt,
                    updatedAt: row.updatedAt
                )
            )
        }
        return observations
    }

    public func markDeleted(
        observationID: String,
        in scope: MemoryScope,
        updatedAt: Date
    ) async throws {
        try transaction {
            try withStatement(
                """
                UPDATE memory_observations
                SET state = 'deleted', updated_at = ?
                WHERE observation_id = ?
                  AND user_id = ?
                  AND character_id = ?
                  AND state = 'active';
                """
            ) { statement in
                try bind(dateString(updatedAt), at: 1, to: statement)
                try bind(observationID, at: 2, to: statement)
                try bind(scope.userID, at: 3, to: statement)
                try bind(scope.characterID, at: 4, to: statement)
                try stepExpectingDone(statement)
            }

            let database = try databaseHandle()
            guard sqlite3_changes(database) == 1 else {
                throw SQLiteObservationStoreError.unknownObservation(
                    observationID
                )
            }

            try withStatement(
                """
                DELETE FROM memory_observation_embeddings
                WHERE observation_id = ?;
                """
            ) { statement in
                try bind(observationID, at: 1, to: statement)
                try stepExpectingDone(statement)
            }
        }
    }

    public func close() async {
        guard let database = connection.handle else {
            return
        }
        sqlite3_close_v2(database)
        connection.handle = nil
    }

    private func existingSchemaVersion() throws -> Int? {
        try withStatement(
            """
            SELECT value FROM schema_metadata
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
            let value = try text(at: 0, from: statement, column: "schema_version")
            guard let version = Int(value) else {
                throw SQLiteObservationStoreError.invalidStoredValue(
                    column: "schema_version"
                )
            }
            return version
        }
    }

    private func labels(
        forObservationID observationID: String
    ) throws -> (labels: [MemoryLabel], version: String) {
        try withStatement(
            """
            SELECT label, classifier_version
            FROM memory_observation_labels
            WHERE observation_id = ?
            ORDER BY label ASC;
            """
        ) { statement in
            try bind(observationID, at: 1, to: statement)

            var labels: [MemoryLabel] = []
            var versions: Set<String> = []
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
                guard let label = MemoryLabel(rawValue: labelValue) else {
                    throw SQLiteObservationStoreError.invalidStoredValue(
                        column: "label"
                    )
                }
                labels.append(label)
                versions.insert(
                    try text(
                        at: 1,
                        from: statement,
                        column: "classifier_version"
                    )
                )
            }

            guard !labels.isEmpty, versions.count == 1,
                  let version = versions.first else {
                throw SQLiteObservationStoreError.invalidStoredValue(
                    column: "classifier_version"
                )
            }
            return (labels, version)
        }
    }

    private func observationRow(
        from statement: OpaquePointer
    ) throws -> ObservationRow {
        let stateValue = try text(
            at: 7,
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
            sourceMessageID: try text(
                at: 1,
                from: statement,
                column: "source_message_id"
            ),
            sessionID: try text(
                at: 2,
                from: statement,
                column: "session_id"
            ),
            userID: try text(
                at: 3,
                from: statement,
                column: "user_id"
            ),
            characterID: try text(
                at: 4,
                from: statement,
                column: "character_id"
            ),
            occurredAt: try date(
                at: 5,
                from: statement,
                column: "occurred_at"
            ),
            rawText: try text(
                at: 6,
                from: statement,
                column: "raw_text"
            ),
            state: state,
            validFrom: try optionalDate(
                at: 8,
                from: statement,
                column: "valid_from"
            ),
            validUntil: try optionalDate(
                at: 9,
                from: statement,
                column: "valid_until"
            ),
            supersedesObservationID: try optionalText(
                at: 10,
                from: statement,
                column: "supersedes_observation_id"
            ),
            createdAt: try date(
                at: 11,
                from: statement,
                column: "created_at"
            ),
            updatedAt: try date(
                at: 12,
                from: statement,
                column: "updated_at"
            )
        )
    }

    private func execute(_ sql: String) throws {
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
            }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw SQLiteObservationStoreError.statementFailed(message)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func withStatement<Result>(
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

    private func bind(
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

    private func bind(
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

    private func stepExpectingDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw statementError()
        }
    }

    private func text(
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

    private func optionalText(
        at index: Int32,
        from statement: OpaquePointer,
        column: String
    ) throws -> String? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
            return nil
        }
        return try text(at: index, from: statement, column: column)
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

    private func optionalDate(
        at index: Int32,
        from statement: OpaquePointer,
        column: String
    ) throws -> Date? {
        guard let storedValue = try optionalText(
            at: index,
            from: statement,
            column: column
        ) else {
            return nil
        }
        guard let date = dateFormatter.date(from: storedValue) else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: column
            )
        }
        return date
    }

    private func dateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private func databaseHandle() throws -> OpaquePointer {
        guard let database = connection.handle else {
            throw SQLiteObservationStoreError.databaseNotInitialized
        }
        return database
    }

    private func statementError() -> SQLiteObservationStoreError {
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
    let sourceMessageID: String
    let sessionID: String
    let userID: String
    let characterID: String
    let occurredAt: Date
    let rawText: String
    let state: MemoryObservationState
    let validFrom: Date?
    let validUntil: Date?
    let supersedesObservationID: String?
    let createdAt: Date
    let updatedAt: Date
}
