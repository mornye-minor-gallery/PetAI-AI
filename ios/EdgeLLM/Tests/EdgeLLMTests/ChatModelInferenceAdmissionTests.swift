import XCTest
import Testing
@testable import EdgeLLM

final class ChatModelInferenceAdmissionTests: XCTestCase {
    func testEachModelUsesItsOwnInferenceBoundary() throws {
        for (profile, required) in [(ChatModelProfile.e2b, UInt64(256 * 1_048_576)),
                                    (.e4b, UInt64(384 * 1_048_576))] {
            let policy = profile.iosCPUInferenceAdmission
            XCTAssertEqual(policy.requiredBytes, required)
            XCTAssertThrowsError(try policy.check(availableBytes: required - 1, pressure: .normal)) {
                XCTAssertEqual($0 as? InferenceMemoryDeferred,
                    .init(availableBytes: required - 1, requiredBytes: required, pressure: .normal))
            }
            XCTAssertNoThrow(try policy.check(availableBytes: required, pressure: .normal))
            XCTAssertNoThrow(try policy.check(availableBytes: required + 1, pressure: .normal))
            for pressure in [InferenceMemoryPressure.warning, .critical] {
                XCTAssertThrowsError(try policy.check(availableBytes: required * 4, pressure: pressure))
            }
            XCTAssertNoThrow(try policy.check(availableBytes: required, pressure: .normal))
        }
    }

    func testSameHeadroomAllowsE2BButDefersE4B() throws {
        let available: UInt64 = 320 * 1_048_576
        try ChatModelProfile.e2b.iosCPUInferenceAdmission.check(availableBytes: available, pressure: .normal)
        XCTAssertThrowsError(try ChatModelProfile.e4b.iosCPUInferenceAdmission.check(
            availableBytes: available, pressure: .normal))
    }

    func testPreferenceChangeCannotLowerRunningE4BPolicy() throws {
        let selection = ChatModelLaunchSelection()
        XCTAssertTrue(selection.configure(.e4b))
        let active = selection.capture()
        XCTAssertFalse(selection.configure(.e2b))
        XCTAssertEqual(selection.capture(), active)
        XCTAssertThrowsError(try active.iosCPUInferenceAdmission.check(
            availableBytes: 320 * 1_048_576, pressure: .normal))
    }
}

@Test(arguments: ChatModelProfile.allCases)
func selectedModelAdmissionReachesDialogueController(profile: ChatModelProfile) async throws {
    let policy = profile.iosCPUInferenceAdmission
    let fixture = try ChatControllerFixture(checkInferenceAdmission: { _ in
        try policy.check(availableBytes: 320 * 1_048_576, pressure: .normal)
    })
    defer { fixture.remove() }
    await fixture.controller.initialize()
    await fixture.controller.send(json: fixture.request("model-policy", "안녕"))
    if profile == .e4b {
        #expect(await fixture.runtime.generationCount == 0)
        #expect(fixture.events.snapshot().last?.code == "inference_memory_insufficient")
        #expect(try fixture.store.load()?.chatTurns.isEmpty ?? true)
    } else {
        #expect(await fixture.runtime.generationCount == 1)
        #expect(try fixture.store.load()?.chatTurns.last?.status == .completed)
    }
}
