public enum EdgeMemSQLiteSchema {
    /// Version 2 adds `gemma_header` label provenance. Earlier prototype
    /// tables are intentionally reset; canonical version 1 is migrated.
    public static let version = 2

    public static let migrateVersion1ToVersion2 = [
        """
        DROP INDEX IF EXISTS idx_observation_labels_label;
        """,
        """
        ALTER TABLE observation_labels
        RENAME TO observation_labels_v1;
        """,
        """
        CREATE TABLE observation_labels (
            observation_id TEXT NOT NULL
                REFERENCES observations(id)
                ON DELETE CASCADE,
            label TEXT NOT NULL
                CHECK (label IN ('preference', 'event')),
            score REAL,
            source TEXT NOT NULL
                CHECK (
                    source IN (
                        'regex',
                        'prototype',
                        'regex+prototype',
                        'future_mlp',
                        'gemma_header'
                    )
                ),
            classifier_version TEXT NOT NULL,
            PRIMARY KEY (observation_id, label)
        );
        """,
        """
        INSERT INTO observation_labels(
            observation_id,
            label,
            score,
            source,
            classifier_version
        )
        SELECT
            observation_id,
            label,
            score,
            source,
            classifier_version
        FROM observation_labels_v1;
        """,
        """
        DROP TABLE observation_labels_v1;
        """,
        """
        UPDATE schema_metadata
        SET value = '2'
        WHERE key = 'schema_version';
        """,
    ]

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
        CREATE TABLE IF NOT EXISTS conversation_turns (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK (sequence >= 0),
            role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
            text TEXT NOT NULL CHECK (length(trim(text)) > 0),
            occurred_at TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            deleted_at TEXT,
            UNIQUE(session_id, sequence)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_turns_session_sequence
        ON conversation_turns(session_id, sequence);
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_turns_scope_time
        ON conversation_turns(
            user_id,
            character_id,
            occurred_at
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS gate_results (
            id TEXT PRIMARY KEY,
            turn_id TEXT NOT NULL
                REFERENCES conversation_turns(id)
                ON DELETE CASCADE,
            regex_preference_hit INTEGER NOT NULL
                CHECK (regex_preference_hit IN (0, 1)),
            regex_event_hit INTEGER NOT NULL
                CHECK (regex_event_hit IN (0, 1)),
            regex_hard_ignore INTEGER NOT NULL
                CHECK (regex_hard_ignore IN (0, 1)),
            matched_patterns_json TEXT NOT NULL,
            preference_score REAL,
            event_score REAL,
            decision TEXT NOT NULL
                CHECK (decision IN ('none', 'preference', 'event', 'both')),
            preference_threshold REAL NOT NULL,
            event_threshold REAL NOT NULL,
            classifier_version TEXT NOT NULL,
            embedding_model_id TEXT,
            created_at TEXT NOT NULL
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_gate_results_turn
        ON gate_results(turn_id);
        """,
        """
        CREATE TABLE IF NOT EXISTS observations (
            id TEXT PRIMARY KEY,
            turn_id TEXT NOT NULL UNIQUE
                REFERENCES conversation_turns(id)
                ON DELETE CASCADE,
            state TEXT NOT NULL CHECK (state IN ('active', 'deleted')),
            created_at TEXT NOT NULL
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_observations_state
        ON observations(state);
        """,
        """
        CREATE TABLE IF NOT EXISTS observation_labels (
            observation_id TEXT NOT NULL
                REFERENCES observations(id)
                ON DELETE CASCADE,
            label TEXT NOT NULL
                CHECK (label IN ('preference', 'event')),
            score REAL,
            source TEXT NOT NULL
                CHECK (
                    source IN (
                        'regex',
                        'prototype',
                        'regex+prototype',
                        'future_mlp',
                        'gemma_header'
                    )
                ),
            classifier_version TEXT NOT NULL,
            PRIMARY KEY (observation_id, label)
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_observation_labels_label
        ON observation_labels(label, observation_id);
        """,
        """
        CREATE TABLE IF NOT EXISTS observation_embeddings (
            observation_id TEXT NOT NULL
                REFERENCES observations(id)
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
