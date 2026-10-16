import Foundation

/// Product profiles are independent of the shared embedding package. Select one
/// at process launch; changing a preference must not replace an in-flight engine.
public enum ChatModelProfile: String, Codable, Sendable, CaseIterable {
    case e2b = "gemma-e2b"
    case e4b = "gemma-e4b"

    public var contextTokens: Int { 4096 }
    public var cacheNamespace: String { "\(rawValue)-ctx\(contextTokens)" }
    public var optionalRelativePath: String? {
        self == .e4b ? "PetAIModels/gemma-4-E4B-it.litertlm" : nil
    }
    // Reproducible text-only artifact: ai/models/gemma-e4b-text-only.json.
    public var byteLength: Int64? { self == .e4b ? 3_317_633_552 : nil }
    public var sha256: String? {
        self == .e4b ? "1469010f9d32b55e9f92d2e1dd4a4a198c30207fad4ced5098a5b568dc647262" : nil
    }

    public var iosCPUAdmission: ModelLoadMemoryAdmission {
        // CPU / 4K / prefill128, six short/long iPhone runs per model (2026-10-07).
        // Peak incremental footprints: E2B 682,445,320; E4B 886,378,720 bytes.
        // Rounded thresholds include policy margins, not measured safe boundaries.
        // E4B measurements used output256; product output512 needs device QA.
        // These are NOT Android/GPU thresholds or a guarantee against later OOM.
        .init(requiredBytes: self == .e2b ? 1_073_741_824 : 1_342_177_280)
    }

    /// Headroom for a NEW job on the already loaded CPU / 4K / prefill128 engine.
    /// Keep this separate from the initial model-load allocation budget.
    public var iosCPUInferenceAdmission: InferenceMemoryAdmission {
        switch self {
        case .e2b:
            // Six iPhone first-turn runs (2026-10-07, output256): maximum
            // turn_start→turn_end footprint growth 119,570,600 bytes.
            return .init(requiredBytes: 268_435_456) // 256 MiB, existing policy margin.
        case .e4b:
            // PROVISIONAL, not an iPhone-validated boundary. Mac CPU comparison
            // (2026-10-17, XNNPACK scale fix, 4K, prefill128, input1536/3584,
            // output128/512, two repeats each): first-prefill-marker sample to
            // peak footprint grew 288.845–296.704 MiB. 384 MiB adds ~87 MiB to
            // that observed maximum. Mac footprint is NOT iOS available memory;
            // validate on device before treating this as a supported safe limit.
            return .init(requiredBytes: 402_653_184) // 384 MiB.
        }
    }

    public func resolve(base: RuntimeModelAssets, documents: URL) throws -> RuntimeModelAssets {
        guard let path = optionalRelativePath else { return base }
        let url = documents.appendingPathComponent(path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? NSNumber, size.int64Value == byteLength else {
            throw ChatModelProfileError.optionalModelMissing
        }
        return .init(languageModelURL: url, embeddingModelURL: base.embeddingModelURL,
                     tokenizerURL: base.tokenizerURL, version: base.version)
    }

    public func validateDigest(_ digest: String) throws {
        if let expected = sha256, expected != digest { throw ChatModelProfileError.invalidModel }
        // A renamed E4B must not inherit the lower E2B admission threshold.
        if self == .e2b, digest == Self.e4b.sha256 { throw ChatModelProfileError.invalidModel }
    }

    public func validateConfiguration(_ configuration: SLMConfiguration) throws {
        guard configuration.dialogueBudget.contextTokens == contextTokens else {
            throw ChatModelProfileError.invalidConfiguration
        }
    }
}

public enum ChatModelProfileError: Error, LocalizedError {
    case optionalModelMissing, invalidModel, invalidConfiguration
    public var errorDescription: String? {
        switch self {
        case .optionalModelMissing: "고급 모델 파일이 준비되지 않았어요. 설정에서 기본 모델로 바꾸거나 E4B 파일을 준비해 주세요."
        case .invalidModel: "선택한 모델과 파일이 맞지 않아요. 모델 파일을 다시 확인해 주세요."
        case .invalidConfiguration: "선택한 모델의 문맥 크기와 실행 설정이 맞지 않아요."
        }
    }
}
