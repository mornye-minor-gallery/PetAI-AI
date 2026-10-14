import Foundation

/// Device-local recent context. EdgeMem owns durable P/E memories; this file owns
/// only the bounded prompt window and its clocks. Login does not select a file.
public struct DialogueSessionFileStore: Sendable {
    public let fileURL: URL
    private let characterID: String?
    private let acceptsUnscopedCheckpoint: Bool

    public init(fileURL: URL, characterID: String? = nil, acceptsUnscopedCheckpoint: Bool = false) {
        self.fileURL = fileURL
        self.characterID = characterID
        self.acceptsUnscopedCheckpoint = acceptsUnscopedCheckpoint
    }

    public static func character(_ id: String, in directory: URL,
                                 legacyFileURL: URL? = nil, legacyCharacterID: String = "elena") throws -> Self {
        let id = try DialogueCharacterID(id).value
        let target = directory.appendingPathComponent("characters", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true).appendingPathComponent("recent-turns.json")
        if id == legacyCharacterID, let legacyFileURL,
           FileManager.default.fileExists(atPath: legacyFileURL.path) {
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw DialogueSessionError.invalidCheckpoint
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Both files are in the same app-private volume. Rename leaves one authoritative copy.
            try FileManager.default.moveItem(at: legacyFileURL, to: target)
        }
        return Self(fileURL: target, characterID: id, acceptsUnscopedCheckpoint: id == legacyCharacterID)
    }

    public static func deviceLocal() throws -> Self {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return Self(fileURL: support.appendingPathComponent("PetAI/ChatSession/recent-turns.json"))
    }

    /// Enumerates only device-local conversations that have a durable checkpoint.
    public static func existingCharacterIDs(in directory: URL,
                                            legacyFileURL: URL? = nil,
                                            legacyCharacterID: String = "elena") throws -> [String] {
        if let legacyFileURL {
            _ = try character(legacyCharacterID, in: directory, legacyFileURL: legacyFileURL,
                              legacyCharacterID: legacyCharacterID)
        }
        let root = directory.appendingPathComponent("characters", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .compactMap { url -> String? in
                let id = try DialogueCharacterID(url.lastPathComponent).value
                return FileManager.default.fileExists(atPath: url.appendingPathComponent("recent-turns.json").path)
                    ? id : nil
            }.sorted()
    }

    public func load(maximumTurnCount: Int? = nil) throws -> RoutedPersonaSessionContext? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let checkpoint = try JSONDecoder().decode(DialogueSessionCheckpoint.self,
            from: Data(contentsOf: fileURL))
        if let characterID, checkpoint.characterID != characterID,
           !(acceptsUnscopedCheckpoint && checkpoint.characterID == nil) {
            throw DialogueSessionError.invalidCheckpoint
        }
        let session = try RoutedPersonaSessionContext(checkpoint: checkpoint, maximumTurnCount: maximumTurnCount)
        let entries = session.recentEntries
        guard entries.allSatisfy({ entry in
            switch entry {
            case .request(let turn):
                return !turn.userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    (turn.status != .completed || !turn.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .homeLine(let line):
                return !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }), Set(entries.map(\.id)).count == entries.count else {
            throw DialogueSessionError.invalidCheckpoint
        }
        return session
    }

    @discardableResult
    public func recordHomeLine(in session: inout RoutedPersonaSessionContext,
                               id: String, text: String, topic: HomeTopicContext? = nil) throws -> RoutedPersonaSessionContext.CommitResult {
        var candidate = session
        let result = try candidate.appendHomeLine(id: id, text: text, topic: topic)
        if result == .committed {
            try save(candidate)
            session = candidate
        }
        return result
    }

    /// Admission is durable before the in-memory session claims the request.
    public func beginRequest(in session: inout RoutedPersonaSessionContext,
                             requestID: String, userMessage: String) throws -> DialogueSessionSnapshot {
        var candidate = session
        let snapshot = try candidate.beginRequest(requestID: requestID, userMessage: userMessage)
        try save(candidate)
        session = candidate
        return snapshot
    }

    /// A terminal turn becomes authoritative only after its checkpoint is durable.
    @discardableResult
    public func finishRequest(in session: inout RoutedPersonaSessionContext,
                              requestID: String, status: ChatTurn.Status,
                              assistantMessage: String? = nil,
                              worldInfo: WorldInfoTransaction? = nil) throws -> RoutedPersonaSessionContext.CommitResult {
        var candidate = session
        let result = try candidate.finishRequest(requestID: requestID, status: status,
            assistantMessage: assistantMessage, worldInfo: worldInfo)
        if result == .committed {
            try save(candidate)
            session = candidate
        }
        return result
    }

    public func save(_ session: RoutedPersonaSessionContext) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)
        var checkpoint = session.checkpoint()
        checkpoint.characterID = characterID
        let data = try JSONEncoder().encode(checkpoint)
        // A process killed during a write keeps either the old or new checkpoint.
        try data.write(to: fileURL, options: .atomic)
    }

    public func compact(in session: inout RoutedPersonaSessionContext,
                        retaining entries: [RecentDialogueEntry], summary: String?, modelIdentifier: String?) throws {
        var candidate = session
        try candidate.compact(retaining: entries, summary: summary, modelIdentifier: modelIdentifier)
        try save(candidate)
        session = candidate
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
#if !os(Android)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
#endif
    }
}
