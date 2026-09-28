import Foundation
import SQLite3

extension SQLiteObservationStore {
    public func diary(characterID: String, localDate: String) throws -> DailyDiary? {
        try withStatement(
            """
            SELECT character_id, local_date, title, body, completed_at
            FROM daily_diaries WHERE character_id = ? AND local_date = ?;
            """
        ) { statement in
            try bind(characterID, at: 1, to: statement)
            try bind(localDate, at: 2, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw statementError() }
            return try diaryRow(statement)
        }
    }

    public func allDiaries() throws -> [DailyDiary] {
        try withStatement(
            """
            SELECT character_id, local_date, title, body, completed_at
            FROM daily_diaries ORDER BY local_date DESC, character_id ASC;
            """
        ) { statement in
            var diaries: [DailyDiary] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return diaries }
                guard result == SQLITE_ROW else { throw statementError() }
                diaries.append(try diaryRow(statement))
            }
        }
    }

    /// A successful first write wins. Later P/E changes cannot rewrite a completed day.
    public func insertDiaryIfAbsent(
        characterID: String, localDate: String, draft: DailyDiaryDraft
    ) throws -> DailyDiary {
        _ = try DailyDiaryDay(localDate)
        guard !characterID.isEmpty, draft.isValid
        else { throw DailyDiaryError.invalidDraft }
        return try transaction {
            try withStatement(
                """
                INSERT OR IGNORE INTO daily_diaries
                    (character_id, local_date, title, body, completed_at)
                VALUES (?, ?, ?, ?, ?);
                """
            ) { statement in
                try bind(characterID, at: 1, to: statement)
                try bind(localDate, at: 2, to: statement)
                try bind(draft.title, at: 3, to: statement)
                try bind(draft.body, at: 4, to: statement)
                try bind(dateString(Date()), at: 5, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
            }
            guard let stored = try diary(characterID: characterID, localDate: localDate) else {
                throw SQLiteObservationStoreError.statementFailed("Diary write was not verified")
            }
            return stored
        }
    }

    private func diaryRow(_ statement: OpaquePointer) throws -> DailyDiary {
        let value = try text(at: 4, from: statement, column: "completed_at")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let completedAt = formatter.date(from: value) else {
            throw SQLiteObservationStoreError.invalidStoredValue(column: "completed_at")
        }
        return DailyDiary(
            characterID: try text(at: 0, from: statement, column: "character_id"),
            localDate: try text(at: 1, from: statement, column: "local_date"),
            title: try text(at: 2, from: statement, column: "title"),
            body: try text(at: 3, from: statement, column: "body"),
            completedAt: completedAt
        )
    }
}
