import XCTest
@testable import HITMCore

final class RuleUsageTests: XCTestCase {
    private let t1 = Date(timeIntervalSince1970: 1_000), t2 = Date(timeIntervalSince1970: 2_000)

    func testCountIncreasesPerAllowAndNeverOnAsk() {
        var log = RuleUsageLog()
        log.record(.allow(ruleID: "r1"), at: t1)
        log.record(.allow(ruleID: "r1"), at: t2)
        log.record(.ask(reason: "because"), at: t2)
        log.record(.allow(ruleID: "r2"), at: t1)
        XCTAssertEqual(log.usage(for: "r1"), RuleUsage(count: 2, lastUsed: t2))
        XCTAssertEqual(log.usage(for: "r2"), RuleUsage(count: 1, lastUsed: t1))
        XCTAssertEqual(log.usage(for: "never"), RuleUsage(count: 0, lastUsed: nil))
    }

    func testAskLeavesTheLogUnchanged() {
        var log = RuleUsageLog()
        log.record(.allow(ruleID: "r1"), at: t1)
        let before = log
        log.record(.ask(reason: "x"), at: t2)
        XCTAssertEqual(log, before)
    }

    func testUsageLogRoundTripsThroughJSON() throws {
        var log = RuleUsageLog()
        log.record(.allow(ruleID: "r1"), at: t1)
        XCTAssertEqual(try JSONDecoder().decode(RuleUsageLog.self, from: JSONEncoder().encode(log)), log)
    }

    func testAskExplanationQuotesTheReasonAndSaysAPersonDecides() {
        let text = RuleBook(rules: [], onboardedProjects: []).explanation(for: .ask(reason: "No standing rule covers this command."))
        XCTAssertTrue(text.contains("No standing rule covers this command."))
        XCTAssertTrue(text.lowercased().contains("person"))
    }

    func testAllowExplanationNamesTheRuleItsScopeAndTheFloorCheck() {
        let r = Rule(id: "r1", family: .localGit, command: "git", subcommand: "status", scope: .projectFolder("/proj"),
                     effect: .allow, projectID: "p1")
        let text = RuleBook(rules: [r], onboardedProjects: ["p1"]).explanation(for: .allow(ruleID: "r1"))
        for part in ["r1", "git status", "/proj", "safety floor"] { XCTAssertTrue(text.contains(part), part) }
    }

    func testAllowExplanationForAnUnknownRuleIdStillSaysSomethingPlain() {
        let text = RuleBook(rules: [], onboardedProjects: []).explanation(for: .allow(ruleID: "ghost"))
        XCTAssertTrue(text.contains("ghost"))
    }

    func testDecodeRejectsNegativeOrAbsurdCounts() {
        func decodes(_ count: String) -> Bool {
            let json = #"{"byRule":{"r":{"count":\#(count)}}}"#
            return (try? JSONDecoder().decode(RuleUsageLog.self, from: Data(json.utf8))) != nil
        }
        XCTAssertTrue(decodes("0"))
        XCTAssertTrue(decodes("5"))
        XCTAssertFalse(decodes("-1"))
        XCTAssertFalse(decodes("9223372036854775807"))
        XCTAssertFalse(decodes("2000000000"))
    }

    func testRecordingNeverTrapsAtTheBound() throws {
        let json = #"{"byRule":{"r":{"count":1000000000}}}"#
        var log = try JSONDecoder().decode(RuleUsageLog.self, from: Data(json.utf8))
        log.record(.allow(ruleID: "r"), at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(log.usage(for: "r").count, 1_000_000_000)
    }
}
