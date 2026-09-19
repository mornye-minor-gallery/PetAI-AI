import Foundation
import XCTest
@testable import ResourceBench

final class CommandStoreTests: XCTestCase {
    func store() throws -> CommandStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try CommandStore(root: root, runID: UUID(), ownerID: UUID())
        try store.transition(to: .bootReady)
        return store
    }
    func command(_ store: CommandStore, operation: String = "prepare") -> BenchCommand {
        BenchCommand(runID: store.state.runID, operationID: UUID(), ownerID: store.state.ownerID,
                     expectedRevision: store.state.revision, operation: operation,
                     manifestSHA256: String(repeating: "a", count: 64))
    }
    func testDuplicateCannotExecuteTwice() throws {
        let s = try store(), c = command(s)
        XCTAssertTrue(try s.accept(c, digest: "first"))
        XCTAssertFalse(try s.accept(c, digest: "first"))
        XCTAssertThrowsError(try s.accept(c, digest: "different"))
    }
    func testRevisionAndOwnerAreAuthoritative() throws {
        let s = try store(), c = command(s)
        try s.transition(to: .preparing)
        XCTAssertThrowsError(try s.accept(c, digest: "one"))
        var alien = command(s)
        alien.ownerID = UUID()
        XCTAssertThrowsError(try s.accept(alien, digest: "two"))
    }
    func testRestartPreservesReceiptAndNeverResumes() throws {
        let s = try store(), c = command(s)
        XCTAssertTrue(try s.accept(c, digest: "first"))
        try s.transition(to: .preparing)
        let reopened = try CommandStore(root: s.root, runID: s.state.runID, ownerID: s.state.ownerID)
        XCTAssertEqual(reopened.state.phase, .failed)
        XCTAssertEqual(reopened.state.error, "interrupted")
        XCTAssertFalse(try reopened.accept(c, digest: "first"))
    }
    func testHeartbeatDoesNotChangeCASRevision() throws {
        let s = try store(), revision = s.state.revision
        try s.heartbeat()
        XCTAssertEqual(s.state.revision, revision)
        XCTAssertEqual(s.state.heartbeatSeq, 1)
    }
    func testIncompleteOrTraversalCommandRejected() throws {
        let s = try store(), c = command(s)
        let bytes = try BenchJSON.encoder.encode(c)
        let name = "\(c.operationID.uuidString.lowercased()).\(BenchIO.digest(bytes)).json"
        XCTAssertEqual(try BenchCommand.decode(name: name, data: bytes).operationID, c.operationID)
        XCTAssertThrowsError(try BenchCommand.decode(name: name, data: bytes + Data(" ".utf8)))
        XCTAssertThrowsError(try BenchCommand.decode(name: "../" + name, data: bytes))
    }
    func testIllegalTransitionDoesNotChangeState() throws {
        let s = try store()
        XCTAssertThrowsError(try s.transition(to: .finished))
        XCTAssertEqual(s.state.phase, .bootReady)
    }
}
