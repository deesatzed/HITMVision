import XCTest
import HITMCore
@testable import CockpitUI

// All data here is PROTOTYPE SAMPLE DATA from CockpitUI/SampleData.swift; the gate and log are the real HITMCore ones.
@MainActor
final class CockpitStoreTests: XCTestCase {
    private let universal: Set<String> = ["T7", "T8", "T9"]       // deploy, external send, irreversible
    private let profileFloor: Set<String> = ["T5", "T6"]          // domain logic, safety check
    private let unsureAgent: Set<String> = ["T4", "T10", "T11"]   // confidence under 0.70

    private func ids(_ tasks: [SampleTask]) -> Set<String> { Set(tasks.map { $0.id }) }

    func testLightWaitingCounts() {
        let s = CockpitStore()
        XCTAssertEqual(ids(s.waiting), universal.union(unsureAgent))
        XCTAssertEqual(s.waiting.count, 6)
        XCTAssertEqual(s.quiet.count, sampleTasks.count - 6)
        XCTAssertEqual(s.interruptionCount, 6)
        XCTAssertTrue(universal.allSatisfy { id in s.gate(for: sampleTasks.first { $0.id == id }!).fromFloor })
    }

    func testStrictAddsTheTwoProfileFloorItems() {
        let s = CockpitStore()
        s.setProfile(.strict)
        XCTAssertEqual(ids(s.waiting), universal.union(unsureAgent).union(profileFloor))
        XCTAssertEqual(s.waiting.count, 8)
        XCTAssertTrue(profileFloor.allSatisfy { id in s.gate(for: sampleTasks.first { $0.id == id }!).fromFloor })
    }

    func testUnsureBehavesLikeStrict() {
        let a = CockpitStore(), b = CockpitStore()
        a.setProfile(.strict); b.setProfile(.unsure)
        XCTAssertEqual(a.waiting.map { $0.id }, b.waiting.map { $0.id })
        XCTAssertEqual(b.waiting.count, 8)
    }

    func testWaitingIsFloorFirstThenTaskOrder() {
        let s = CockpitStore()
        s.setProfile(.strict)
        let order = s.waiting.map { $0.id }
        XCTAssertEqual(order, ["T5", "T6", "T7", "T8", "T9", "T4", "T10", "T11"])
        let floorFlags = s.waiting.map { s.gate(for: $0).fromFloor }
        XCTAssertEqual(floorFlags, [true, true, true, true, true, false, false, false])
    }

    func testResolvingMovesToDecidedAndLogs() {
        let s = CockpitStore()
        let t7 = sampleTasks.first { $0.id == "T7" }!
        let t4 = sampleTasks.first { $0.id == "T4" }!
        let t8 = sampleTasks.first { $0.id == "T8" }!
        s.resolve(t7, .passed); s.resolve(t4, .modified("keep one file")); s.resolve(t8, .rejected)
        XCTAssertEqual(ids(s.decided), ["T7", "T4", "T8"])
        XCTAssertEqual(s.waiting.count, 3)
        XCTAssertFalse(s.waiting.contains { $0.id == "T7" })
        XCTAssertEqual(s.log.events.map { $0.kind }, ["pass", "modify", "reject"])
        XCTAssertTrue(s.log.events[1].payload.contains("keep one file"))
        XCTAssertEqual(s.label(s.resolutions["T8"]!), "Rejected")
    }

    func testSubmitIntentLogsWithSource() {
        let s = CockpitStore()
        s.submitIntent("  build a thing  ")
        s.submitIntent("spoken one", source: .voice)
        s.submitIntent("   ")
        XCTAssertEqual(s.log.events.count, 2)
        XCTAssertEqual(s.log.events[0].kind, "intent")
        XCTAssertEqual(s.log.events[0].payload, "typed: build a thing")
        XCTAssertEqual(s.log.events[1].payload, "voice: spoken one")
        XCTAssertEqual(s.requests, ["build a thing", "spoken one"])
        XCTAssertEqual(IntentSource.typed.rawValue, "typed")
    }

    func testOfferAfterTwoAgentUnsurePassesAndAcceptChangesOnlyThreshold() {
        let s = CockpitStore()
        let t4 = sampleTasks.first { $0.id == "T4" }!, t10 = sampleTasks.first { $0.id == "T10" }!
        let t7 = sampleTasks.first { $0.id == "T7" }!
        s.resolve(t7, .passed)                      // floor pass does not count
        XCTAssertEqual(s.smartPasses, 0)
        s.resolve(t4, .passed)
        XCTAssertFalse(s.showOffer)
        s.resolve(t10, .passed)
        XCTAssertTrue(s.showOffer)
        let floorBefore = ids(s.waiting).intersection(universal)
        s.answerOffer(accept: true)
        XCTAssertFalse(s.showOffer)
        XCTAssertEqual(s.threshold, relaxedConfidenceThreshold)
        // T11 (0.68) is now under the relaxed 0.60? No: 0.68 >= 0.60 so it goes quiet; floor items untouched.
        XCTAssertFalse(s.waiting.contains { $0.id == "T11" })
        XCTAssertEqual(ids(s.waiting).intersection(universal), floorBefore)
        XCTAssertEqual(s.choice, .light)
        s.setProfile(.strict)
        XCTAssertTrue(["T5", "T6"].allSatisfy { id in s.waiting.contains { $0.id == id } })
    }

    func testResetRestores() {
        let s = CockpitStore()
        s.setProfile(.strict)
        s.resolve(sampleTasks.first { $0.id == "T5" }!, .passed)
        s.resolve(sampleTasks.first { $0.id == "T4" }!, .passed)
        s.resolve(sampleTasks.first { $0.id == "T10" }!, .passed)
        s.answerOffer(accept: true)
        s.submitIntent("x")
        s.reset()
        XCTAssertEqual(s.choice, .light)
        XCTAssertTrue(s.decided.isEmpty)
        XCTAssertTrue(s.log.events.isEmpty)
        XCTAssertEqual(s.threshold, sampleConfidenceThreshold)
        XCTAssertNil(s.lastIntent)
        XCTAssertTrue(s.requests.isEmpty)
        XCTAssertEqual(s.smartPasses, 0)
        XCTAssertFalse(s.showOffer)
        XCTAssertEqual(s.waiting.count, 6)
    }
}

// Focus state for the decision card and the sample proof field.
@MainActor
final class CockpitFocusTests: XCTestCase {
    private func task(_ id: String) -> SampleTask { sampleTasks.first { $0.id == id }! }

    func testDefaultFocusIsFirstWaiting() {
        let s = CockpitStore()
        XCTAssertEqual(s.focusedTask?.id, s.waiting.first?.id)
        XCTAssertNil(s.focusedID)
    }

    func testFocusSticksWhenWaitingAndIgnoredOtherwise() {
        let s = CockpitStore()
        s.focus("T9")
        XCTAssertEqual(s.focusedTask?.id, "T9")
        s.focus("T1")                     // quiet, not waiting
        XCTAssertEqual(s.focusedTask?.id, "T9")
        s.focus("nope")
        XCTAssertEqual(s.focusedTask?.id, "T9")
    }

    func testResolvingFocusedMovesToNextWaiting() {
        let s = CockpitStore()
        s.focus("T8")
        s.resolve(task("T8"), .passed)
        XCTAssertEqual(s.focusedTask?.id, "T9")
        XCTAssertEqual(s.focusedID, "T9")
    }

    func testResolvingFocusedLastItemWrapsToFirstWaitingOrNil() {
        let s = CockpitStore()
        s.focus("T11")
        s.resolve(task("T11"), .rejected)
        XCTAssertEqual(s.focusedID, s.waiting.first?.id)
        XCTAssertNotNil(s.focusedID)
        for t in s.waiting { s.resolve(t, .passed) }
        XCTAssertNil(s.focusedTask)
        XCTAssertNil(s.focusedID)
    }

    func testResolvingNonFocusedKeepsFocus() {
        let s = CockpitStore()
        s.focus("T9")
        s.resolve(task("T7"), .passed)
        XCTAssertEqual(s.focusedTask?.id, "T9")
    }

    func testProfileChangeRemovingFocusedMovesFocus() {
        let s = CockpitStore()
        s.setProfile(.strict)
        s.focus("T5")                     // profile-floor item
        s.setProfile(.light)              // T5 leaves the queue
        XCTAssertEqual(s.focusedID, s.waiting.first?.id)
        XCTAssertNotEqual(s.focusedID, "T5")
    }

    func testFocusDoesNotJumpBackAfterProfileRoundTrip() {
        let s = CockpitStore()
        s.setProfile(.strict)
        s.focus("T5")
        s.setProfile(.light)
        let after = s.focusedID
        s.setProfile(.strict)             // T5 is waiting again, but focus must not return to it
        XCTAssertEqual(s.focusedID, after)
        XCTAssertNotEqual(s.focusedTask?.id, "T5")
    }

    func testChangingFocusDoesNotChangeWaitingOrder() {
        let s = CockpitStore()
        let before = s.waiting.map { $0.id }
        s.focus("T11"); s.focus("T9"); s.focus("T4")
        XCTAssertEqual(s.waiting.map { $0.id }, before)
    }

    func testResetClearsFocus() {
        let s = CockpitStore()
        s.focus("T9")
        s.reset()
        XCTAssertNil(s.focusedID)
        XCTAssertEqual(s.focusedTask?.id, s.waiting.first?.id)
    }

    func testSampleProofHasBothStates() {
        XCTAssertTrue(sampleTasks.contains { !$0.proof.isEmpty })
        XCTAssertTrue(sampleTasks.contains { $0.proof.isEmpty })
        // At least one waiting item in the default (Light) queue carries proof and one does not.
        let s = CockpitStore()
        XCTAssertTrue(s.waiting.contains { !$0.proof.isEmpty })
        XCTAssertTrue(s.waiting.contains { $0.proof.isEmpty })
    }
}
