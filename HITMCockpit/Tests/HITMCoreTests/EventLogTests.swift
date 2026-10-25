import XCTest
@testable import HITMCore

final class EventLogTests: XCTestCase {
    func testRevisionsStrictlyIncrease() {
        var log = EventLog()
        let a = log.append(kind: "task", payload: "one", author: "human")
        let b = log.append(kind: "task", payload: "two", author: "human")
        XCTAssertEqual(a.revision, 1)
        XCTAssertEqual(b.revision, 2)
    }

    func testNewLogGetsNewSessionID() {
        XCTAssertNotEqual(EventLog().sessionID, EventLog().sessionID)
    }

    func testCorrectionAppendsAndKeepsOriginal() {
        var log = EventLog()
        let original = log.append(kind: "memory", payload: "X", author: "agent")
        let fix = log.correct(original, reason: "wrong", author: "human")
        XCTAssertEqual(log.events.count, 2)
        XCTAssertEqual(log.events[0], original)
        XCTAssertEqual(fix.kind, "correction")
        XCTAssertGreaterThan(fix.revision, original.revision)
        XCTAssertEqual(log.events[1], fix)
        XCTAssertEqual(fix.payload, "rev 1: wrong")
        XCTAssertEqual(fix.revision, 2)
    }

    func testRevisionsContinueAcrossAppendCorrectAppend() {
        var log = EventLog()
        let first = log.append(kind: "task", payload: "one", author: "human")
        log.correct(first, reason: "wrong", author: "human")
        log.append(kind: "task", payload: "two", author: "human")
        XCTAssertEqual(log.events.map(\.revision), [1, 2, 3])
    }

    private func requireSendable<T: Sendable>(_ t: T) {}

    func testTypesAreSendable() {
        var log = EventLog()
        let e = log.append(kind: "task", payload: "one", author: "human")
        requireSendable(e)
        requireSendable(log)
    }
}
