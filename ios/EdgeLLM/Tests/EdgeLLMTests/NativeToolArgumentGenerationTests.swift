import Foundation
import XCTest
@testable import EdgeLLM

final class NativeToolArgumentGenerationTests: XCTestCase {
    func testEveryToolDeclaresItsArgumentSource() {
        XCTAssertEqual(NativeToolKind.getCurrentTime.argumentSource, .fixed(.getCurrentTime))
        XCTAssertEqual(NativeToolKind.listAlarms.argumentSource, .fixed(.listAlarms))
        for tool in NativeToolKind.allCases {
            switch tool.argumentSource {
            case .fixed(let arguments): XCTAssertEqual(arguments.tool, tool)
            case .model(let kind): XCTAssertEqual(kind.nativeTool, tool)
            }
        }
    }

    func testModelGenerationKindsRoundTripToTheirDeclaredSource() {
        for kind in NativeToolGenerationKind.allCases {
            XCTAssertEqual(kind.nativeTool.argumentSource, .model(kind))
        }
    }

    func testParameterlessToolsDoNotLoadPromptsOrInvokeGenerator() async throws {
        for tool in [NativeToolKind.getCurrentTime, .listAlarms] {
            let generator = ForbiddenArgumentGenerator()
            let coordinator = NativeToolProposalCoordinator { _ in .null }
            let harness = NativeToolProposalHarness(router: FixedToolRouter(tool: tool),
                promptRegistry: .init { _ in XCTFail("Fixed arguments must not load a model prompt"); return nil },
                coordinator: coordinator, generator: generator)
            let outcome = try await harness.prepare(requestID: "fixed-\(tool.rawValue)", userMessage: "합성 요청",
                promptContext: .init(now: Date(), calendar: .current), allowedTools: [tool])
            guard case .proposal(let draft, let validated, let event) = outcome else {
                return XCTFail("Expected a fixed-argument proposal")
            }
            XCTAssertEqual(draft.tool, tool)
            XCTAssertEqual(validated.tool, tool)
            XCTAssertEqual(event.state, .proposalReady)
            let calls = await generator.calls
            XCTAssertEqual(calls, 0)
        }
        XCTAssertTrue(NativeToolKind.listAlarms.requiresConfirmation)
        XCTAssertFalse(NativeToolKind.getCurrentTime.requiresConfirmation)
    }
}

private struct FixedToolRouter: NativeToolRouting {
    let tool: NativeToolKind
    func route(_ utterance: String) -> NativeToolRoute { .tool(tool) }
}

private actor ForbiddenArgumentGenerator: NativeToolProposalGenerating {
    var calls = 0
    func generateFunctionCall(_ request: NativeToolGenerationRequest) throws -> NativeToolFunctionCall {
        calls += 1
        throw RuntimeError.runtimeBusy
    }
}
