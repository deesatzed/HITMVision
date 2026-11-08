import XCTest
import HITMCore
@testable import CockpitUI

// Cards here are written by the test itself into a temp inbox; they are fixtures for the store's behavior, not model output.
@MainActor
final class LiveStoreTests: XCTestCase {
    private func repo() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)") }
    private func card(_ id: String, status: CardStatus, needsHuman: Bool, cls: ActionClass = .routine, reasons: [String] = ["note"],
                      at: Date = Date()) -> ReviewCard {
        ReviewCard(id: id, createdAt: at, intent: "i", title: "Title \(id)", steps: [], overallClass: cls, branch: "hitm/\(id)",
                   changedPaths: ["a.py"], diff: "+x", diffTruncated: false, addedLines: 1, removedLines: 0, needsHuman: needsHuman,
                   detailLevel: 1, reasons: reasons, gateFailed: false, models: [:], status: status)
    }
    private func inbox(_ r: URL) -> CardInbox { CardInbox(directory: r.appendingPathComponent(".hitm/inbox")) }

    func testSampleModeIsUnchangedUntilLiveIsEnabled() {
        let s = CockpitStore()
        XCTAssertFalse(s.isLive); XCTAssertEqual(s.tasks.count, sampleTasks.count)
    }

    func testLiveShowsRealCardsNotSampleOnes() throws {
        let r = repo(); let box = inbox(r)
        try box.write(card("a1", status: .pending, needsHuman: true, cls: .deploy, reasons: ["Universal floor: deploy"]))
        try box.write(card("b2", status: .quietPassed, needsHuman: false))
        try box.write(card("f3", status: .failed, needsHuman: false))
        let s = CockpitStore(); s.enableLive(repo: r, reviewer: "me", apply: nil)
        XCTAssertTrue(s.isLive); XCTAssertEqual(s.tasks.count, 2)
        XCTAssertEqual(s.waiting.map(\.id), ["a1"]); XCTAssertEqual(s.quiet.map(\.id), ["b2"]); XCTAssertEqual(s.failedRuns, 1)
        XCTAssertTrue(s.tasks.allSatisfy { !$0.isSample })
        XCTAssertEqual(s.gate(for: s.waiting[0]).kind, .floorUniversal)
    }

    func testGateAskedIsLabeledAsTheGateNotAsAgentConfidence() throws {
        let r = repo()
        try inbox(r).write(card("g1", status: .pending, needsHuman: true, reasons: ["The summary does not match the class."]))
        let s = CockpitStore(); s.enableLive(repo: r, reviewer: "me", apply: nil)
        let g = s.gate(for: s.waiting[0])
        XCTAssertEqual(g.kind, .gateAsked); XCTAssertEqual(g.tag, "GATE ASKED"); XCTAssertFalse(g.fromFloor)
    }

    func testPassRecordsANamedDecisionThenAppliesAndSurvivesReload() throws {
        let r = repo(); let box = inbox(r)
        try box.write(card("p1", status: .pending, needsHuman: true))
        var applied: [(String, Bool)] = []
        let s = CockpitStore(); s.enableLive(repo: r, reviewer: " rev ") { c, pass in applied.append((c.id, pass)) }
        s.resolve(s.waiting[0], .passed)
        XCTAssertEqual(try box.load("p1").status, .passed); XCTAssertEqual(try box.load("p1").decidedBy, "rev")
        XCTAssertEqual(applied.count, 1); XCTAssertEqual(applied[0].0, "p1"); XCTAssertTrue(applied[0].1)
        XCTAssertTrue(s.waiting.isEmpty); XCTAssertEqual(s.decided.map(\.id), ["p1"])
        let s2 = CockpitStore(); s2.enableLive(repo: r, reviewer: "x", apply: nil)
        XCTAssertEqual(s2.decided.map(\.id), ["p1"]); XCTAssertTrue(s2.waiting.isEmpty)
    }

    func testRejectWithoutApplyTellsTheUserToSync() throws {
        let r = repo(); let box = inbox(r)
        try box.write(card("r1", status: .pending, needsHuman: true))
        let s = CockpitStore(); s.enableLive(repo: r, reviewer: "me", apply: nil)
        s.resolve(s.waiting[0], .rejected)
        XCTAssertEqual(try box.load("r1").status, .rejected)
        XCTAssertTrue(s.liveError?.contains("sync") ?? false)
    }

    func testFailedApplyKeepsTheRecordedDecisionAndSaysSo() throws {
        struct Boom: Error {}
        let r = repo(); try inbox(r).write(card("e1", status: .pending, needsHuman: true))
        let s = CockpitStore(); s.enableLive(repo: r, reviewer: "me") { _, _ in throw Boom() }
        s.resolve(s.waiting[0], .passed)
        XCTAssertEqual(try inbox(r).load("e1").status, .passed)
        XCTAssertTrue(s.liveError?.contains("not updated") ?? false)
    }

    func testModifyIsRefusedForLiveCardsAndNothingChanges() throws {
        let r = repo(); try inbox(r).write(card("m1", status: .pending, needsHuman: true))
        let s = CockpitStore(); s.enableLive(repo: r, reviewer: "me", apply: nil)
        s.resolve(s.waiting[0], .modified("please change"))
        XCTAssertEqual(try inbox(r).load("m1").status, .pending); XCTAssertEqual(s.waiting.count, 1); XCTAssertNotNil(s.liveError)
    }

    func testDecisionAlreadyMadeElsewhereCannotBeOverwritten() throws {
        let r = repo(); let box = inbox(r)
        try box.write(card("d1", status: .pending, needsHuman: true))
        let s = CockpitStore(); s.enableLive(repo: r, reviewer: "me", apply: nil)
        let stale = s.waiting[0]
        try box.decide("d1", to: .rejected, by: "other")            // decided from the terminal meanwhile
        s.resolve(stale, .passed)
        XCTAssertEqual(try box.load("d1").status, .rejected)
        XCTAssertNotNil(s.liveError)
    }

    func testRefreshPicksUpNewCardsAndNoOfferIsShownInLiveMode() throws {
        let r = repo(); let box = inbox(r)
        let s = CockpitStore(); s.enableLive(repo: r, reviewer: "me", apply: nil)
        XCTAssertTrue(s.tasks.isEmpty)
        try box.write(card("n1", status: .pending, needsHuman: true))
        s.refreshLive()
        XCTAssertEqual(s.waiting.map(\.id), ["n1"]); XCTAssertFalse(s.showOffer)
    }

    func testBriefForALiveCardMakesNoSampleClaims() throws {
        let r = repo(); try inbox(r).write(card("b1", status: .pending, needsHuman: true, cls: .irreversible, reasons: ["Universal floor: irreversible"]))
        let s = CockpitStore(); s.enableLive(repo: r, reviewer: "me", apply: nil)
        let t = s.waiting[0]
        let b = try XCTUnwrap(DecisionBrief(task: t, gate: s.gate(for: t), profile: .light, waiting: s.waiting))
        XCTAssertFalse(b.contentIsSample); XCTAssertTrue(b.next.pass.contains("hitm/b1")); XCTAssertTrue(b.how.method.contains("recorded"))
    }
}
