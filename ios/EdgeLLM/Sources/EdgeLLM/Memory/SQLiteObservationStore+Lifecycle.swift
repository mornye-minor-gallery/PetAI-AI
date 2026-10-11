import Foundation
import SQLite3

extension SQLiteObservationStore {
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

        do {
            try openDatabase()
            if try isLegacyPrototypeDatabase() {
                closeDatabase()
                try Self.removeDatabase(at: databaseURL)
                try openDatabase()
            }
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

    func closeDatabase() {
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

    private func excludeFromCloudBackup(_ directory: URL) throws {
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}
