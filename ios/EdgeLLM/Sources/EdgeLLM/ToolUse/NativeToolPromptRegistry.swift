import CryptoKit
import Foundation

public struct NativeToolPromptContext: Equatable, Sendable {
    public let currentDate: String
    public let currentDateTime: String
    public let timeZoneIdentifier: String

    public init(
        currentDate: String,
        currentDateTime: String,
        timeZoneIdentifier: String
    ) {
        self.currentDate = currentDate
        self.currentDateTime = currentDateTime
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public init(now: Date, calendar: Calendar) {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.calendar = calendar
        dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateTimeFormatter.timeZone = calendar.timeZone
        dateTimeFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        self.init(
            currentDate: dateFormatter.string(from: now),
            currentDateTime: dateTimeFormatter.string(from: now),
            timeZoneIdentifier: calendar.timeZone.identifier
        )
    }
}

public struct NativeToolPrompt: Equatable, Sendable {
    public let tool: NativeToolKind
    public let source: String
    public let sourceSHA256: String

    public init(
        tool: NativeToolKind,
        source: String,
        sourceSHA256: String
    ) {
        self.tool = tool
        self.source = source
        self.sourceSHA256 = sourceSHA256
    }

    public func rendered(with context: NativeToolPromptContext) -> String {
        source
            + """


            ## 기기 기준

            - currentDate: \(context.currentDate)
            - currentDateTime: \(context.currentDateTime)
            - timeZoneIdentifier: \(context.timeZoneIdentifier)
            """
    }
}

public enum NativeToolPromptRegistryError: Error, Equatable, Sendable {
    case resourceMissing(tool: NativeToolKind)
    case invalidUTF8(tool: NativeToolKind)
    case checksumMismatch(
        tool: NativeToolKind,
        expected: String,
        actual: String
    )
}

public struct NativeToolPromptRegistry: Sendable {
    public typealias Loader = @Sendable (_ fileName: String) -> Data?

    private static let expectedSHA256: [NativeToolKind: String] = [
        .getStepCount:
            "9098d2a37dc606b9c9ecd5503305e1273e08281eda3fa0095d025465ed513620",
        .createAlarm:
            "b34d7b54bf1f168264217cb8c3ace36716aa62ba10633a93cf70a8bf47c5ed80",
        .listAlarms:
            "846e4107d334528b7061d9d178b9013979a94dca9a7927392e1bdf092fa395b7",
        .createTimer:
            "165c110033aa83532e154a3b5d34d372e180fdd0578ca0aa026cf02620768ad5",
        .scheduleLocalNotification:
            "7ad8d04470b4b21e515904ac3f0cd9cad71860f49d99a42dc8df3e4a4543e4a1",
        .getCalendarEvents:
            "c381cc8ed63f2d52f170eab6e6ffcf17d2637742008f56f9d56349b44c5a8a3e",
        .createCalendarEvent:
            "ad43178bd2fc8501c6ac52a46924214285b36f16437ee8e9fc6be49377b66b9a",
    ]

    private let loader: Loader

    public init() {
        self.loader = Self.bundleLoader
    }

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func prompt(for tool: NativeToolKind) throws -> NativeToolPrompt {
        let fileName = tool.rawValue + ".md"
        guard let data = loader(fileName) else {
            throw NativeToolPromptRegistryError.resourceMissing(tool: tool)
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw NativeToolPromptRegistryError.invalidUTF8(tool: tool)
        }
        let actual = Self.sha256(data)
        let expected = Self.expectedSHA256[tool]!
        guard actual == expected else {
            throw NativeToolPromptRegistryError.checksumMismatch(
                tool: tool,
                expected: expected,
                actual: actual
            )
        }
        return NativeToolPrompt(
            tool: tool,
            source: source,
            sourceSHA256: actual
        )
    }

    public static func expectedChecksum(for tool: NativeToolKind) -> String {
        expectedSHA256[tool]!
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func bundleLoader(fileName: String) -> Data? {
        let parts = fileName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let resource = String(parts[0])
        let fileExtension = String(parts[1])

        #if SWIFT_PACKAGE
        let bundles = [Bundle.module]
        #else
        let bundles = [Bundle.main, Bundle(for: NativeToolPromptBundleToken.self)]
        #endif

        for bundle in bundles {
            let candidates = [
                bundle.url(
                    forResource: resource,
                    withExtension: fileExtension,
                    subdirectory: "Prompts/ToolUse"
                ),
                bundle.url(
                    forResource: resource,
                    withExtension: fileExtension,
                    subdirectory: "EdgeLLMPrompts"
                ),
                bundle.url(forResource: resource, withExtension: fileExtension),
            ]
            if let url = candidates.compactMap({ $0 }).first,
                let data = try? Data(contentsOf: url)
            {
                return data
            }
        }
        return nil
    }
}

private final class NativeToolPromptBundleToken {}
