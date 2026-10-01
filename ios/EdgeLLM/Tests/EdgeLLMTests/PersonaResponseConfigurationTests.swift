import Foundation
import Testing
@testable import EdgeLLM

@Test func promptComponentsCanBeAblatedIndependently() throws {
    let prompts = try testPersona()
    let profile = UserProfileContext(characterName: "루미")
    for persona in [false, true] {
        for session in [false, true] {
            for name in [false, true] {
                for memory in [false, true] {
                    let config = PersonaResponseConfiguration(
                        includePersona: persona, includeSessionContext: session,
                        enforceCharacterName: name, memoryClassification: memory
                    )
                    var expected: [String] = []
                    if persona {
                        expected.append(prompts.core.replacingOccurrences(of: "{{char}}", with: "루미"))
                        expected.append("## 이번 응답의 활성 장면 카드\n장면 규칙 다른 장면 규칙은 이번 응답에 사용하지 않는다.")
                    }
                    if session { expected.append(profile.promptSection()) }
                    if memory { expected.append(MemoryTaggedChatPrompt.wrappedAxesV1) }
                    if name { expected.append(config.nameInstruction(characterName: "루미")) }
                    #expect(prompts.responseSystemPrompt(
                        activeCard: "장면 규칙", userProfileContext: profile, configuration: config
                    ) == expected.joined(separator: "\n\n"))
                    let decoded = try JSONDecoder().decode(
                        PersonaResponseConfiguration.self, from: JSONEncoder().encode(config)
                    )
                    #expect(decoded == config)
                }
            }
        }
    }
}

@Test func productionPersonaConfigurationEnablesResponseAction() throws {
    let prompts = try testPersona()
    let profile = UserProfileContext()
    let expected = [prompts.core.replacingOccurrences(of: "{{char}}", with: "엘레나"), profile.promptSection(), MemoryTaggedChatPrompt.wrappedAxesV1, PersonaResponseConfiguration(enforceCharacterName: true).nameInstruction(characterName: "엘레나")]
        .joined(separator: "\n\n")
    #expect(PersonaResponseConfiguration.production.enforceCharacterName)
    #expect(PersonaResponseConfiguration.production.nameRuleStyle == .responseAction)
    #expect(prompts.responseSystemPrompt(activeCard: nil) == expected)
    #expect(prompts.responseSystemPrompt(activeCard: nil, configuration: .production) == expected)
}

@Test func personaNamePolicyUsesConfiguredIdentity() throws {
    let prompts = try testPersona()
    let result = prompts.responseSystemPrompt(
        activeCard: nil, userProfileContext: UserProfileContext(characterName: "루미"),
        configuration: .init(enforceCharacterName: true, memoryClassification: true)
    )
    #expect(result.contains("캐릭터의 이름은 \"루미\"이다"))
    #expect(result.contains(MemoryTaggedChatPrompt.wrappedAxesV1))
}

@Test func answerOnlyPolicyChangesBothPromptAndProcessing() async throws {
    let config = PersonaResponseConfiguration(enforceCharacterName: false, memoryClassification: false)
    let prompts = try testPersona()
    let expected = [prompts.core.replacingOccurrences(of: "{{char}}", with: "엘레나"), UserProfileContext().promptSection()].joined(separator: "\n\n")
    #expect(prompts.responseSystemPrompt(activeCard: nil, configuration: config) == expected)
    var retries = 0
    let outcome = try await MemoryTaggedChatProcessor.run(
        configuration: config,
        primaryStream: { AsyncThrowingStream { $0.yield("나는 엘레나야."); $0.finish() } },
        retryStream: { retries += 1; return AsyncThrowingStream { $0.finish() } },
        receiveVisibleText: { _ in }
    )
    #expect(outcome.visibleText == "나는 엘레나야.")
    #expect(outcome.commitDecision == nil)
    #expect(retries == 0)
}

@Test func answerOnlyEmptyOutputDoesNotInvokeClassificationRetry() async throws {
    var retries = 0
    let outcome = try await MemoryTaggedChatProcessor.run(
        configuration: .init(enforceCharacterName: true, memoryClassification: false),
        primaryStream: { AsyncThrowingStream { $0.finish() } },
        retryStream: { retries += 1; return AsyncThrowingStream { $0.finish() } },
        receiveVisibleText: { _ in }
    )
    #expect(!outcome.hasVisibleResponse)
    #expect(retries == 0)
}
