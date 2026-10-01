import Foundation

public struct RuntimeModelAssets: Sendable, Equatable {
    public let languageModelURL: URL
    public let embeddingModelURL: URL
    public let tokenizerURL: URL
    public let version: String

    public init(
        languageModelURL: URL,
        embeddingModelURL: URL,
        tokenizerURL: URL,
        version: String
    ) {
        self.languageModelURL = languageModelURL
        self.embeddingModelURL = embeddingModelURL
        self.tokenizerURL = tokenizerURL
        self.version = version
    }
}
