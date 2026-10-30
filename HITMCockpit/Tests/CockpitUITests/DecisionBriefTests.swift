import XCTest
import HITMCore
@testable import CockpitUI

// All tasks here are PROTOTYPE SAMPLE DATA from CockpitUI/SampleData.swift; the gate reasons are the real HITMCore ones.
@MainActor
final class DecisionBriefTests: XCTestCase {
    private func task(_ id: String) -> SampleTask { sampleTasks.first { $0.id == id }! }
    private func brief(_ id: String, _ s: CockpitStore) -> DecisionBrief? {
        DecisionBrief(task: task(id), gate: s.gate(for: task(id)), profile: s.choice, waiting: s.waiting)
    }

    func testUniversalFloorSource() {
        let s = CockpitStore()
        let b = brief("T7", s)!
        XCTAssertEqual(b.why.source, .floorUniversal)
        XCTAssertTrue(b.why.technicalReason.hasPrefix("Universal"))
        XCTAssertEqual(b.what.taskID, "T7")
        XCTAssertEqual(b.what.role, "Implementer")
        XCTAssertEqual(b.scope.text, "This one action only.")
        XCTAssertTrue(b.scope.broaderRulesLater)
    }

    func testStrictProfileFloorSource() {
        let s = CockpitStore()
        s.setProfile(.strict)
        let b = brief("T5", s)!
        XCTAssertEqual(b.why.source, .floorProfile)
        XCTAssertTrue(b.why.technicalReason.contains("strict"))
        XCTAssertTrue(b.how.inputs.contains { $0.contains("Strict") })
    }

    func testAgentConfidenceIncludesThreshold() {
        let s = CockpitStore()
        let b = brief("T4", s)!
        XCTAssertEqual(b.why.source, .agentConfidence)
        XCTAssertTrue(b.why.technicalReason.contains("0.70"))
        XCTAssertTrue(b.why.technicalReason.contains("0.62"))
        XCTAssertTrue(b.how.method.lowercased().contains("sample"))
    }

    func testQuietTaskHasNoBrief() {
        let s = CockpitStore()
        XCTAssertNil(brief("T1", s))
    }

    func testEmptyProofIsNoProofAttached() {
        let s = CockpitStore()
        let t = task("T4")
        XCTAssertTrue(t.proof.isEmpty)
        XCTAssertEqual(brief("T4", s)!.evidence, .noProofAttached)
    }

    func testProofEntriesAreCarriedThrough() {
        let s = CockpitStore()
        let t = SampleTask(id: "TX", title: "x", summary: "x", role: "Planner", action: .deploy, confidence: 0.9,
                           plain: "x", reversible: true, evidence: [], ruleNotes: [], detail: "x",
                           proof: ["Tests: 12 passed, 0 failed."])
        let b = DecisionBrief(task: t, gate: s.gate(for: t), profile: s.choice, waiting: s.waiting)!
        XCTAssertEqual(b.evidence, .proof(["Tests: 12 passed, 0 failed."]))
    }

    func testUnavailableNeverEmptyAndMarked() {
        let s = CockpitStore()
        s.setProfile(.strict)
        for t in s.waiting {
            let b = brief(t.id, s)!
            XCTAssertEqual(b.how.unavailable.count, 3)
            XCTAssertTrue(b.how.unavailable.allSatisfy { $0.status == "Not available in sample mode" })
        }
    }

    func testNextLinesAndUnblocksCountsOnlySameRoleOthers() {
        let s = CockpitStore()
        // Light waiting: T7 T8 T9 T4 T10 T11. Implementer others for T7: T8, T10. Planner others for T4: T9. Reviewer others for T11: none.
        XCTAssertEqual(brief("T7", s)!.next.unblocks.map { $0.id }, ["T8", "T10"])
        XCTAssertEqual(brief("T4", s)!.next.unblocks.map { $0.id }, ["T9"])
        XCTAssertTrue(brief("T11", s)!.next.unblocks.isEmpty)
        let n = brief("T7", s)!.next
        XCTAssertFalse(n.pass.isEmpty); XCTAssertFalse(n.modify.isEmpty); XCTAssertFalse(n.reject.isEmpty)
    }

    func testFloorUniversalInputsHaveNoConfidence() {
        let s = CockpitStore()
        let b = brief("T7", s)!
        XCTAssertEqual(b.why.source, .floorUniversal)
        XCTAssertEqual(b.how.inputs.count, 2)
        XCTAssertTrue(b.how.inputs[0].contains("deploy"))
        XCTAssertTrue(b.how.inputs[1].contains("Light"))
        XCTAssertFalse(b.how.inputs.contains { $0.contains("confidence") })
    }

    func testFloorProfileInputsHaveNoConfidence() {
        let s = CockpitStore()
        s.setProfile(.strict)
        let b = brief("T6", s)!
        XCTAssertEqual(b.why.source, .floorProfile)
        XCTAssertEqual(b.how.inputs.count, 2)
        XCTAssertFalse(b.how.inputs.contains { $0.contains("confidence") })
    }

    func testAgentConfidenceInputsListConfidence() {
        let s = CockpitStore()
        let b = brief("T4", s)!
        XCTAssertEqual(b.how.inputs.count, 3)
        XCTAssertTrue(b.how.inputs[2].contains("0.62"))
    }

    func testStrictFloorWinsOverLowConfidence() {
        let s = CockpitStore()
        s.setProfile(.strict)
        let t = SampleTask(id: "TL", title: "x", summary: "x", role: "Planner", action: .editDomainLogic, confidence: 0.10,
                           plain: "x", reversible: true, evidence: [], ruleNotes: [], detail: "x")
        let g = s.gate(for: t)
        XCTAssertEqual(g.kind, .floorProfile)
        let b = DecisionBrief(task: t, gate: g, profile: s.choice, waiting: s.waiting)!
        XCTAssertEqual(b.why.source, .floorProfile)
        XCTAssertFalse(b.how.inputs.contains { $0.contains("confidence") })
    }

    func testGateKindIsExplicit() {
        let s = CockpitStore()
        XCTAssertEqual(s.gate(for: task("T7")).kind, .floorUniversal)
        XCTAssertEqual(s.gate(for: task("T4")).kind, .agentConfidence)
        XCTAssertEqual(s.gate(for: task("T1")).kind, .quiet)
    }

    func testSampleTasksAreMarkedSampleAndBriefCarriesIt() {
        let s = CockpitStore()
        XCTAssertTrue(sampleTasks.allSatisfy { $0.isSample })
        XCTAssertTrue(brief("T7", s)!.contentIsSample)
        var real = task("T7"); real.isSample = false
        let b = DecisionBrief(task: real, gate: s.gate(for: real), profile: s.choice, waiting: s.waiting)!
        XCTAssertFalse(b.contentIsSample)
    }

    func testBriefCarriesReversibilityAndExactDetail() {
        let s = CockpitStore()
        let b = brief("T8", s)!
        XCTAssertFalse(b.what.reversible)
        XCTAssertEqual(b.what.detail, "12 files, 3.1 MB.")
        XCTAssertFalse(b.what.summary.isEmpty)
    }

    func testDuplicateProofLinesArePreserved() {
        let s = CockpitStore()
        var t = task("T7"); t.proof = ["same", "same"]
        let b = DecisionBrief(task: t, gate: s.gate(for: t), profile: s.choice, waiting: s.waiting)!
        XCTAssertEqual(b.evidence, .proof(["same", "same"]))
    }
}
