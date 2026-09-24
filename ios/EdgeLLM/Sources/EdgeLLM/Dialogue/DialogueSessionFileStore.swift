import Foundation

/// Device-local recent context. EdgeMem owns durable P/E memories; this file owns
/// only the bounded prompt window and its clocks. Login does not select a file.
public struct DialogueSessionFileStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func deviceLocal() throws -> Self {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return Self(fileURL: support.appendingPathComponent("PetAI/ChatSession/recent-turns.json"))
    }

    public func load() throws -> RoutedPersonaSessionContext? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let checkpoint = try JSONDecoder().decode(DialogueSessionCheckpoint.self,
            from: Data(contentsOf: fileURL))
        let session = try RoutedPersonaSessionContext(checkpoint: checkpoint)
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
                               id: String, text: String) throws -> RoutedPersonaSessionContext.CommitResult {
        var candidate = session
        let result = try candidate.appendHomeLine(id: id, text: text)
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
        let data = try JSONEncoder().encode(session.checkpoint())
        // A process killed during a write keeps either the old or new checkpoint.
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
