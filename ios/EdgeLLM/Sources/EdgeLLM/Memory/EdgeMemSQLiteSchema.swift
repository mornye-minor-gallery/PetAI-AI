public enum EdgeMemSQLiteSchema {
    public static let version = 1

    /// This schema does not open or encrypt a database by itself. The current
    /// prototype store is app-private but unencrypted. A production store must
    /// add database encryption without changing this logical schema.
    public static let statements = [
        """
        PRAGMA foreign_keys = ON;
        """,
        """
        CREATE TABLE IF NOT EXISTS schema_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_observations (
            observation_id TEXT PRIMARY KEY,
            source_message_id TEXT NOT NULL UNIQUE,
            session_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            occurred_at TEXT NOT NULL,
            raw_text TEXT NOT NULL CHECK (length(trim(raw_text)) > 0),
            state TEXT NOT NULL CHECK (state IN ('active', 'deleted')),
            valid_from TEXT,
            valid_until TEXT,
            supersedes_observation_id TEXT
                REFERENCES memory_observations(observation_id),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_memory_observations_scope
        ON memory_observations(
            user_id,
            character_id,
            state,
            occurred_at
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_memory_observations_session
        ON memory_observations(session_id, occurred_at);
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_observation_labels (
            observation_id TEXT NOT NULL
                REFERENCES memory_observations(observation_id)
                ON DELETE CASCADE,
            label TEXT NOT NULL
                CHECK (label IN ('preference', 'event')),
            classifier_version TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (observation_id, label)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_memory_observation_labels_label
        ON memory_observation_labels(label, observation_id);
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_observation_embeddings (
            observation_id TEXT NOT NULL
                REFERENCES memory_observations(observation_id)
                ON DELETE CASCADE,
            model_id TEXT NOT NULL,
            dimension INTEGER NOT NULL CHECK (dimension > 0),
            vector BLOB NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (observation_id, model_id)
        );
        """,
    ]
}
