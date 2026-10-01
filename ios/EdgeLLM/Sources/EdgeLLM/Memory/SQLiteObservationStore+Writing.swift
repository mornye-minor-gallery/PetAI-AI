#if os(Android)
import Crypto
#else
import CryptoKit
#endif
import Foundation
import SQLite3

extension SQLiteObservationStore {
    /// No suspension is allowed between BEGIN and COMMIT on this actor's connection.
    public func saveMemory(_ write: MemoryPreparedWrite) throws -> MemoryRememberResult {
        try Task.checkCancellation()
        return try transaction {
            let request = write.request
            let turn = try insertUserTurn(
                id: request.sourceMessageID, sessionID: request.sessionID,
                scope: request.scope, rawText: request.rawText, occurredAt: request.occurredAt)
            try insertGateResult(MemoryGateResult(
                id: write.gateResultID, turnID: turn.id,
                decision: write.decision, createdAt: write.createdAt))
            let result = write.result(for: turn)
            if let observation = result.observation {
                try insertObservation(observation, embedding: write.embedding)
            } else if write.embedding != nil {
                throw SQLiteObservationStoreError.invalidEmbedding("Unexpected embedding for skipped memory")
            }
            try Task.checkCancellation()
            return result
        }
    }

    func insertUserTurn(
        id: String,
        sessionID: String,
        scope: MemoryScope,
        rawText: String,
        occurredAt: Date
    ) throws -> MemoryConversationTurn {
        let sequence = try nextSequence(in: sessionID)
        let contentHash = SHA256.hash(data: Data(rawText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        try withStatement(
            """
            INSERT INTO conversation_turns(
                id,
                user_id,
                character_id,
                session_id,
                sequence,
                role,
                text,
                occurred_at,
                content_hash
            ) VALUES (?, ?, ?, ?, ?, 'user', ?, ?, ?);
            """
        ) { statement in
            try bind(id, at: 1, to: statement)
            try bind(scope.userID, at: 2, to: statement)
            try bind(scope.characterID, at: 3, to: statement)
            try bind(sessionID, at: 4, to: statement)
            try bind(sequence, at: 5, to: statement)
            try bind(rawText, at: 6, to: statement)
            try bind(dateString(occurredAt), at: 7, to: statement)
            try bind(contentHash, at: 8, to: statement)
            try stepExpectingDone(statement)
        }

        return MemoryConversationTurn(
            id: id,
            sessionID: sessionID,
            sequence: sequence,
            scope: scope,
            rawText: rawText,
            occurredAt: occurredAt,
            contentHash: contentHash
        )
    }

    private func insertGateResult(
        _ result: MemoryGateResult
    ) throws {
        let decision = result.decision
        let patternsData = try JSONEncoder().encode(
            decision.regex.matchedPatterns
        )
        guard let patternsJSON = String(
            data: patternsData,
            encoding: .utf8
        ) else {
            throw SQLiteObservationStoreError.invalidStoredValue(
                column: "matched_patterns_json"
            )
        }

        try withStatement(
            """
            INSERT INTO gate_results(
                id,
                turn_id,
                regex_preference_hit,
                regex_event_hit,
                regex_hard_ignore,
                matched_patterns_json,
                preference_score,
                event_score,
                decision,
                preference_threshold,
                event_threshold,
                classifier_version,
                embedding_model_id,
                created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        ) { statement in
            try bind(result.id, at: 1, to: statement)
            try bind(result.turnID, at: 2, to: statement)
            try bind(decision.regex.preferenceHit, at: 3, to: statement)
            try bind(decision.regex.eventHit, at: 4, to: statement)
            try bind(decision.regex.hardIgnore, at: 5, to: statement)
            try bind(patternsJSON, at: 6, to: statement)
            try bind(decision.preferenceScore, at: 7, to: statement)
            try bind(decision.eventScore, at: 8, to: statement)
            try bind(decision.label.rawValue, at: 9, to: statement)
            try bind(decision.preferenceThreshold, at: 10, to: statement)
            try bind(decision.eventThreshold, at: 11, to: statement)
            try bind(decision.classifierVersion, at: 12, to: statement)
            try bind(decision.embeddingModelID, at: 13, to: statement)
            try bind(dateString(result.createdAt), at: 14, to: statement)
            try stepExpectingDone(statement)
        }
    }

    private func insertObservation(
        _ observation: MemoryObservation,
        embedding: MemoryObservationEmbedding?
    ) throws {
        if let embedding {
            try validate(embedding, for: observation)
        }

        try withStatement(
            """
            INSERT INTO observations(
                id,
                turn_id,
                state,
                created_at
            ) VALUES (?, ?, ?, ?);
            """
        ) { statement in
            try bind(observation.id, at: 1, to: statement)
            try bind(observation.turnID, at: 2, to: statement)
            try bind(observation.state.rawValue, at: 3, to: statement)
            try bind(
                dateString(observation.createdAt),
                at: 4,
                to: statement
            )
            try stepExpectingDone(statement)
        }

        for evidence in observation.labelEvidence {
            try withStatement(
                """
                INSERT INTO observation_labels(
                    observation_id,
                    label,
                    score,
                    source,
                    classifier_version
                ) VALUES (?, ?, ?, ?, ?);
                """
            ) { statement in
                try bind(observation.id, at: 1, to: statement)
                try bind(
                    evidence.label.rawValue,
                    at: 2,
                    to: statement
                )
                try bind(evidence.score, at: 3, to: statement)
                try bind(
                    evidence.source.rawValue,
                    at: 4,
                    to: statement
                )
                try bind(
                    evidence.classifierVersion,
                    at: 5,
                    to: statement
                )
                try stepExpectingDone(statement)
            }
        }

        if let embedding {
            try withStatement(
                """
                INSERT INTO observation_embeddings(
                    observation_id,
                    model_id,
                    dimension,
                    vector,
                    created_at
                ) VALUES (?, ?, ?, ?, ?);
                """
            ) { statement in
                try bind(
                    embedding.observationID,
                    at: 1,
                    to: statement
                )
                try bind(embedding.modelID, at: 2, to: statement)
                try bind(embedding.dimension, at: 3, to: statement)
                try bind(
                    vectorData(embedding.vector),
                    at: 4,
                    to: statement
                )
                try bind(
                    dateString(embedding.createdAt),
                    at: 5,
                    to: statement
                )
                try stepExpectingDone(statement)
            }
        }
    }
}
