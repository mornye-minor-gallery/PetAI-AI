import Foundation
import XCTest
@testable import EdgeLLM

final class DialogueCharacterContentTests: XCTestCase {
    func testCharacterSelectionUsesAuthoredIDAndKeepsFilesSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("character-content-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"id":"elena","name":"엘레나","persona":"첫 번째"}"#.utf8)
            .write(to: root.appendingPathComponent("dialogue-content.json"))
        try Data(#"{"id":"lucia","name":"루시아","persona":"두 번째"}"#.utf8)
            .write(to: root.appendingPathComponent("dialogue-content.lucia.json"))

        let first = try DialogueContent.fileURL(for: "elena", in: root)
        let second = try DialogueContent.fileURL(for: "lucia", in: root)
        XCTAssertEqual(try DialogueContent.load(url: first).name, "엘레나")
        XCTAssertEqual(try DialogueContent.load(url: second).name, "루시아")
        XCTAssertEqual(DialogueContent.resourceSuffix(for: first), "")
        XCTAssertEqual(DialogueContent.resourceSuffix(for: second), ".lucia")
        XCTAssertThrowsError(try DialogueContent.fileURL(for: "../elena", in: root))
        XCTAssertThrowsError(try DialogueContent.fileURL(for: "unknown", in: root))
    }
}
