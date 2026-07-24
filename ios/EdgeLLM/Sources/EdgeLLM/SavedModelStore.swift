import Foundation

public enum SavedModelStoreError: Error, Equatable, Sendable {
    case invalidModelFileExtension
    case emptyModelFile
}

extension SavedModelStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidModelFileExtension:
            "Select a .litertlm model file."
        case .emptyModelFile:
            "Select a non-empty .litertlm model file."
        }
    }
}

public struct SavedModelStore: Sendable {
    private static let modelFileName = "selected-model.litertlm"
    private let modelDirectoryOverride: URL?

    public init(modelDirectory: URL? = nil) {
        modelDirectoryOverride = modelDirectory
    }

    public func savedModelURL() throws -> URL {
        try modelDirectory()
            .appendingPathComponent(
                Self.modelFileName,
                isDirectory: false
            )
    }

    public func hasSavedModel() throws -> Bool {
        let modelURL = try savedModelURL()
        return FileManager.default.fileExists(atPath: modelURL.path)
    }

    @discardableResult
    public func importModel(from sourceURL: URL) throws -> URL {
        guard sourceURL.pathExtension.lowercased() == "litertlm" else {
            throw SavedModelStoreError.invalidModelFileExtension
        }

        let isScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceSize = try fileSize(at: sourceURL)
        guard sourceSize > 0 else {
            throw SavedModelStoreError.emptyModelFile
        }

        let fileManager = FileManager.default
        let directory = try modelDirectory()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let destination = try savedModelURL()
        let staging = directory.appendingPathComponent(
            "selected-model-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: staging)
        guard try fileSize(at: staging) == sourceSize else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: staging
            )
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }

        return destination
    }

    public func deleteSavedModel() throws {
        let modelURL = try savedModelURL()
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: modelURL)
    }

    private func modelDirectory() throws -> URL {
        if let modelDirectoryOverride {
            return modelDirectoryOverride
        }

        return try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("EdgeLLM/Models", isDirectory: true)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
