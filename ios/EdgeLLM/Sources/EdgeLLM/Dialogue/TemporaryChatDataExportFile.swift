import Foundation

/// Keeps the share payload in a dedicated directory so dismissal can remove it all.
public struct TemporaryChatDataExportFile {
    public let fileURL: URL
    private let directoryURL: URL

    public init(data: Data, temporaryRoot: URL) throws {
        let directory = temporaryRoot.appendingPathComponent(
            "PetAIDataExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let file = directory.appendingPathComponent("byeolmuri-data.json")
            try data.write(to: file, options: .atomic)
            directoryURL = directory
            fileURL = file
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try FileManager.default.removeItem(at: directoryURL)
    }
}
