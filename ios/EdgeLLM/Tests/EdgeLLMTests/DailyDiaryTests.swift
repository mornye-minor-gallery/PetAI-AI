import Foundation
import Testing
@testable import EdgeLLM

@Suite struct DailyDiaryTests {
    @Test func selectsAtMostTenDistinctObservationsInTimeOrder() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let observations = (0..<24).map { index in
            MemoryObservation(id: "o\(index)", turnID: "t\(index)", sessionID: "s",
                sequence: index, scope: MemoryScope(userID: "local-user", characterID: "character"),
                occurredAt: date.addingTimeInterval(Double(index)), rawText: "기억 \(index)",
                labelEvidence: [MemoryLabelEvidence(label: .event, score: nil, source: .regex,
                    classifierVersion: "test")], createdAt: date)
        }
        var random = DiaryTestRandom()
        let selected = DailyDiaryPrompt.select(observations, using: &random)
        #expect(selected.count == 10)
        #expect(Set(selected.map(\.id)).count == 10)
        #expect(selected.map(\.occurredAt) == selected.map(\.occurredAt).sorted())
    }

    @Test func rejectsMalformedDiaryOutput() {
        #expect(DailyDiaryDraft.parse("not json") == nil)
        #expect(DailyDiaryDraft.parse("{\"title\":\"\",\"body\":\"좋았어요.\"}") == nil)
        #expect(DailyDiaryDraft.parse("{\"title\":\"하루\",\"body\":\"\"}") == nil)
        #expect(DailyDiaryDraft.parse("설명입니다.\n```json\n{\"title\":\"하루\",\"body\":\"쉬었어요.\"}\n```") == nil)
        #expect(DailyDiaryDraft.parse("```json\n{\"title\":\"하루\",\"body\":\"쉬었어요.\"}") == nil)
        #expect(DailyDiaryDraft.parse("```text\n{\"title\":\"하루\",\"body\":\"쉬었어요.\"}\n```") == nil)
    }

    @Test func acceptsDiaryOutput() throws {
        let draft = try #require(DailyDiaryDraft.parse("{\"title\":\"산책한 날\",\"body\":\"저녁에 산책했어요. 돌아와서 쉬었어요.\"}"))
        #expect(draft.title == "산책한 날")
        #expect(draft.body == "저녁에 산책했어요. 돌아와서 쉬었어요.")
    }

    @Test func acceptsFencedDiaryOutput() throws {
        let output = """
            ```json
            {
            "title":"비로 인한 산책 계획 취소 및 휴식",
            "body":"저녁에 산책을 가려고 계획했으나 오후에 비가 와서 산책 계획을 취소하였습니다. 대신 집에서 음악을 듣고 휴식을 취했습니다."
            }
            ```
            """
        let draft = try #require(DailyDiaryDraft.parse(output))
        #expect(draft.title == "비로 인한 산책 계획 취소 및 휴식")
        #expect(draft.body.contains("산책 계획을 취소"))

        let unlabelled = "```\r\n{\"title\":\"하루\",\"body\":\"쉬었어요.\"}\r\n```"
        #expect(DailyDiaryDraft.parse(unlabelled)?.title == "하루")
    }
}

private struct DiaryTestRandom: RandomNumberGenerator {
    private var value: UInt64 = 1
    mutating func next() -> UInt64 {
        value &+= 0x9E3779B97F4A7C15
        return value
    }
}
