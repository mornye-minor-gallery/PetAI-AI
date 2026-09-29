import Foundation

public enum DownloadedModelAssets {
    private struct CachedManifest: Decodable {
        let version: String
        let files: [CachedFile]
    }

    private struct CachedFile: Decodable {
        let role: String
        let relativePath: String
        let byteLength: Int64
    }

    public static func installed(in documents: URL) -> RuntimeModelAssets? {
        let manifestURL = documents.appendingPathComponent(
            "PetAIModels/manifest.json",
            isDirectory: false
        )
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(
                CachedManifest.self,
                from: data
            ),
            let languageModel = installedURL(
                role: "LANGUAGE_MODEL",
                manifest: manifest,
                documents: documents
            ),
            let embeddingModel = installedURL(
                role: "EMBEDDING_MODEL",
                manifest: manifest,
                documents: documents
            ),
            let tokenizer = installedURL(
                role: "TOKENIZER",
                manifest: manifest,
                documents: documents
            )
        else {
            return nil
        }

        return RuntimeModelAssets(
            languageModelURL: languageModel,
            embeddingModelURL: embeddingModel,
            tokenizerURL: tokenizer,
            version: manifest.version
        )
    }

    private static func installedURL(
        role: String,
        manifest: CachedManifest,
        documents: URL
    ) -> URL? {
        let matches = manifest.files.filter { $0.role == role }
        guard
            matches.count == 1,
            matches[0].byteLength > 0,
            matches[0].relativePath.hasPrefix("PetAIModels/"),
            !matches[0].relativePath.contains("\\")
        else {
            return nil
        }

        let root = documents
            .appendingPathComponent("PetAIModels", isDirectory: true)
            .standardizedFileURL.path + "/"
        let candidate = documents
            .appendingPathComponent(matches[0].relativePath)
            .standardizedFileURL
        guard candidate.path.hasPrefix(root) else {
            return nil
        }

        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: candidate.path
            ),
            let size = attributes[.size] as? NSNumber,
            size.int64Value == matches[0].byteLength
        else {
            return nil
        }
        return candidate
    }
}
