import Foundation

enum EmbeddingAssetKind: String, Sendable {
  case model
  case tokenizer

  nonisolated var displayName: String {
    switch self {
    case .model:
      "EmbeddingGemma model"
    case .tokenizer:
      "SentencePiece tokenizer"
    }
  }

  nonisolated fileprivate var requiredFileName: String {
    switch self {
    case .model:
      "embeddinggemma.tflite"
    case .tokenizer:
      "sentencepiece.model"
    }
  }

  nonisolated fileprivate func accepts(_ url: URL) -> Bool {
    switch self {
    case .model:
      url.pathExtension.lowercased() == "tflite"
    case .tokenizer:
      url.lastPathComponent.lowercased() == "sentencepiece.model"
    }
  }
}

enum EmbeddingAssetStoreError: Error {
  case unexpectedFile(kind: EmbeddingAssetKind, name: String)
  case emptyFile(name: String)
}

extension EmbeddingAssetStoreError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .unexpectedFile(let kind, let name):
      "Expected \(kind.requiredFileName), but selected \(name)."
    case .emptyFile(let name):
      "The selected file is empty: \(name)."
    }
  }
}

actor EmbeddingAssetStore {
  struct InstalledAssets: Sendable {
    let modelURL: URL?
    let tokenizerURL: URL?
  }

  private let fileManager = FileManager.default

  func installedAssets() throws -> InstalledAssets {
    let directory = try storageDirectory()
    return InstalledAssets(
      modelURL: existingURL(
        directory.appendingPathComponent(
          EmbeddingAssetKind.model.requiredFileName,
          isDirectory: false
        )
      ),
      tokenizerURL: existingURL(
        directory.appendingPathComponent(
          EmbeddingAssetKind.tokenizer.requiredFileName,
          isDirectory: false
        )
      )
    )
  }

  func importAsset(
    from sourceURL: URL,
    kind: EmbeddingAssetKind
  ) throws -> URL {
    guard kind.accepts(sourceURL) else {
      throw EmbeddingAssetStoreError.unexpectedFile(
        kind: kind,
        name: sourceURL.lastPathComponent
      )
    }

    let isSecurityScoped =
      sourceURL.startAccessingSecurityScopedResource()
    defer {
      if isSecurityScoped {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let sourceAttributes = try fileManager.attributesOfItem(
      atPath: sourceURL.path
    )
    let sourceSize =
      (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
    guard sourceSize > 0 else {
      throw EmbeddingAssetStoreError.emptyFile(
        name: sourceURL.lastPathComponent
      )
    }

    let directory = try storageDirectory()
    let destinationURL = directory.appendingPathComponent(
      kind.requiredFileName,
      isDirectory: false
    )
    let stagingURL = directory.appendingPathComponent(
      ".\(kind.requiredFileName).\(UUID().uuidString).staging",
      isDirectory: false
    )

    defer {
      try? fileManager.removeItem(at: stagingURL)
    }

    try fileManager.copyItem(at: sourceURL, to: stagingURL)

    if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(
        destinationURL,
        withItemAt: stagingURL
      )
    } else {
      try fileManager.moveItem(
        at: stagingURL,
        to: destinationURL
      )
    }

    return destinationURL
  }

  private func storageDirectory() throws -> URL {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = applicationSupport.appendingPathComponent(
      "EmbeddingGemma",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func existingURL(_ url: URL) -> URL? {
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: url.path,
        isDirectory: &isDirectory
      ),
      !isDirectory.boolValue
    else {
      return nil
    }
    return url
  }
}
