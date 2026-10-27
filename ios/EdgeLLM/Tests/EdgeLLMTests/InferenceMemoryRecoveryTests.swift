import Foundation
import Testing
@testable import EdgeLLM

/// Supplies observations, not a second implementation of the admission policy.
/// OS event delivery and the iOS adapter are outside this host test's scope.
private final class SimulatedMemoryObservation: @unchecked Sendable {
    let required: UInt64
    private let lock = NSLock()
    private var available: UInt64
    private var pressure: InferenceMemoryPressure = .normal

    init(profile: ChatModelProfile) {
        required = profile.iosCPUInferenceAdmission.requiredBytes
        available = required
    }

    func update(available: UInt64? = nil, pressure: InferenceMemoryPressure? = nil) {
        lock.withLock {
            if let available { self.available = available }
            if let pressure { self.pressure = pressure }
        }
    }

    func check(_ operation: InferenceOperation) throws {
        try lock.withLock {
            try InferenceMemoryAdmission(requiredBytes: required)
                .check(availableBytes: available, pressure: pressure)
        }
    }
}

@Test(arguments: ChatModelProfile.allCases)
func headroomRecoveryAllowsTheSameQuestionWithoutReload(profile: ChatModelProfile) async throws {
    let observation = SimulatedMemoryObservation(profile: profile)
    let fixture = try ChatControllerFixture(checkInferenceAdmission: observation.check)
    defer { fixture.remove() }
    await fixture.controller.initialize()
    let question = "따뜻한 차를 마시고 싶어."
    observation.update(available: observation.required - 1)
    for index in 0..<3 {
        let id = "blocked-\(index)"
        await fixture.controller.send(json: fixture.request(id, question))
        #expect(fixture.events.snapshot().last?.requestId == id)
        #expect(fixture.events.snapshot().last?.code == "inference_memory_insufficient")
        #expect(try fixture.store.load()?.chatTurns.isEmpty ?? true)
    }
    #expect(await fixture.runtime.generationCount == 0)
    observation.update(available: observation.required)
    await fixture.controller.send(json: fixture.request("retry", question))
    #expect(await fixture.runtime.generationCount == 1)
    let turns = try #require(try fixture.store.load()?.chatTurns)
    #expect(turns.count == 1)
    #expect(turns.first?.userMessage == question)
    #expect(turns.first?.status == .completed)
    #expect(await fixture.runtime.modelPreparationCount == 1)
}

@Test(arguments: ChatModelProfile.allCases)
func headroomRecoveryAloneDoesNotClearPressureButNormalEventDoes(profile: ChatModelProfile) async throws {
    let observation = SimulatedMemoryObservation(profile: profile)
    let fixture = try ChatControllerFixture(checkInferenceAdmission: observation.check)
    defer { fixture.remove() }
    await fixture.controller.initialize()
    observation.update(available: 0, pressure: .warning)
    await fixture.controller.send(json: fixture.request("warning", "안녕"))
    #expect(fixture.events.snapshot().last?.code == "inference_memory_insufficient")
    observation.update(available: 2_147_483_648)
    for index in 0..<5 {
        await fixture.controller.send(json: fixture.request("still-warning-\(index)", "안녕"))
        #expect(fixture.events.snapshot().last?.code == "inference_memory_insufficient")
    }
    #expect(await fixture.runtime.generationCount == 0)
    #expect(try fixture.store.load()?.chatTurns.isEmpty ?? true)
    observation.update(pressure: .normal)
    await fixture.controller.send(json: fixture.request("recovered", "안녕"))
    #expect(await fixture.runtime.generationCount == 1)
    #expect(try fixture.store.load()?.chatTurns.map(\.requestID) == ["recovered"])
    #expect(await fixture.runtime.modelPreparationCount == 1)
}

@Test(arguments: ChatModelProfile.allCases)
func normalPressureAloneDoesNotBypassInsufficientHeadroom(profile: ChatModelProfile) async throws {
    let observation = SimulatedMemoryObservation(profile: profile)
    let fixture = try ChatControllerFixture(checkInferenceAdmission: observation.check)
    defer { fixture.remove() }
    await fixture.controller.initialize()
    observation.update(available: 0, pressure: .critical)
    await fixture.controller.send(json: fixture.request("critical", "안녕"))
    observation.update(pressure: .normal)
    await fixture.controller.send(json: fixture.request("normal-but-low", "안녕"))
    #expect(fixture.events.snapshot().last?.code == "inference_memory_insufficient")
    #expect(await fixture.runtime.generationCount == 0)
    observation.update(available: observation.required)
    await fixture.controller.send(json: fixture.request("recovered", "안녕"))
    #expect(await fixture.runtime.generationCount == 1)
    #expect(try fixture.store.load()?.chatTurns.map(\.requestID) == ["recovered"])
    #expect(await fixture.runtime.modelPreparationCount == 1)
}
