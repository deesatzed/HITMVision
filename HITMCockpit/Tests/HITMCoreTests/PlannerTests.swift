import XCTest
@testable import HITMCore

final class PlannerTests: XCTestCase {
    // Hand-written example of the Proposal schema (not model output).
    let valid = """
    {"title":"Add retry to uploader","steps":[{"text":"Read the uploader code","claimedClass":"routine"},
    {"text":"Add a retry loop","claimedClass":"editDomainLogic"}],"risks":["Might double send"],"questions":["Max retries?"]}
    """

    func decode(_ s: String) -> Result<Proposal, PlannerError> { Proposal.decodeStrict(Data(s.utf8)) }

    func stepsJSON(_ n: Int) -> String {
        let steps = (0..<n).map { _ in "{\"text\":\"s\",\"claimedClass\":\"routine\"}" }.joined(separator: ",")
        return "{\"title\":\"t\",\"steps\":[\(steps)],\"risks\":[],\"questions\":[]}"
    }

    // MARK: decodeStrict
    func testAcceptsValid() throws {
        let p = try decode(valid).get()
        XCTAssertEqual(p.title, "Add retry to uploader")
        XCTAssertEqual(p.steps.count, 2)
        XCTAssertEqual(p.steps[1].claimedClass, .editDomainLogic)
        XCTAssertEqual(p.risks, ["Might double send"])
    }

    func testStepCountBounds() {
        XCTAssertEqual(decode(stepsJSON(0)), .failure(.outOfRange))
        XCTAssertEqual(decode(stepsJSON(9)), .failure(.outOfRange))
        XCTAssertNoThrow(try decode(stepsJSON(1)).get())
        XCTAssertNoThrow(try decode(stepsJSON(8)).get())
    }

    func testMalformedCases() {
        XCTAssertEqual(decode("not json"), .failure(.malformed))
        XCTAssertEqual(decode(valid.replacingOccurrences(of: "\"routine\"", with: "\"bogus\"")), .failure(.malformed))
        XCTAssertEqual(decode("{\"title\":\"t\",\"steps\":[{\"text\":\"a\",\"claimedClass\":\"routine\"}],\"risks\":[]}"), .failure(.malformed))
        XCTAssertEqual(decode("{\"title\":5,\"steps\":[],\"risks\":[],\"questions\":[]}"), .failure(.malformed))
    }

    func testEmptyTitleOrStepIsOutOfRange() {
        XCTAssertEqual(decode(valid.replacingOccurrences(of: "Add retry to uploader", with: " \\u0007 ")), .failure(.outOfRange))
        XCTAssertEqual(decode(valid.replacingOccurrences(of: "Read the uploader code", with: "  ")), .failure(.outOfRange))
    }

    func testListBounds() {
        let six = (0..<6).map { "\"r\($0)\"" }.joined(separator: ",")
        XCTAssertEqual(decode(valid.replacingOccurrences(of: "[\"Might double send\"]", with: "[\(six)]")), .failure(.outOfRange))
        XCTAssertEqual(decode(valid.replacingOccurrences(of: "[\"Max retries?\"]", with: "[\(six)]")), .failure(.outOfRange))
    }

    func testStringsSanitizedAndCapped() throws {
        let long = String(repeating: "a", count: 500)
        let json = "{\"title\":\"  Hello\\u202e\\n\\n  world \",\"steps\":[{\"text\":\"\(long)\",\"claimedClass\":\"routine\"}],\"risks\":[\"x\\u0000y\"],\"questions\":[]}"
        let p = try decode(json).get()
        XCTAssertEqual(p.title, "Hello world")
        XCTAssertEqual(p.steps[0].text.unicodeScalars.count, 301)
        XCTAssertTrue(p.steps[0].text.hasSuffix("…"))
        XCTAssertEqual(p.risks, ["xy"])
    }

    // MARK: ActionClassifier
    func testClassifierTable() {
        let table: [(String, ActionClass)] = [
            ("Delete the old table", .irreversible), ("DROP the index", .irreversible),
            ("remove permanently the logs", .irreversible), ("destroy the cache", .irreversible),
            ("wipe the disk", .irreversible), ("truncate the table", .irreversible),
            ("force push the branch", .irreversible), ("overwrite the config", .irreversible),
            ("deploy to staging", .deploy), ("Release version 2", .deploy), ("publish the package", .deploy),
            ("ship to customers", .deploy), ("push to prod", .deploy),
            ("upload the file", .externalSend), ("send a summary", .externalSend), ("email the team", .externalSend),
            ("post to the channel", .externalSend), ("call a webhook", .externalSend),
            ("use an external service", .externalSend), ("a third-party API", .externalSend), ("add telemetry", .externalSend),
            ("relax a safety margin", .editSafetyCheck), ("change an assertion", .editSafetyCheck),
            ("loosen validation", .editSafetyCheck), ("remove a guard", .editSafetyCheck),
            ("raise the limit", .editSafetyCheck), ("widen tolerance", .editSafetyCheck),
            ("edit permission checks", .editSafetyCheck), ("change auth flow", .editSafetyCheck),
            ("update the business rule", .editDomainLogic), ("rewrite core logic", .editDomainLogic),
            ("fix the calculation", .editDomainLogic), ("adjust pricing", .editDomainLogic),
            ("tune the algorithm", .editDomainLogic),
            ("read the README", .routine), ("rename a local variable", .routine),
        ]
        for (text, cls) in table {
            XCTAssertEqual(ActionClassifier.minimumClass(forStepText: text), cls, text)
        }
    }

    func testClassifierPicksHighestMatchingRule() {
        XCTAssertEqual(ActionClassifier.minimumClass(forStepText: "email the pricing and delete it"), .irreversible)
        XCTAssertEqual(ActionClassifier.minimumClass(forStepText: "send the pricing table"), .externalSend)
    }

    func testSeverityOrder() {
        let order: [ActionClass] = [.routine, .editDomainLogic, .editSafetyCheck, .externalSend, .deploy, .irreversible]
        XCTAssertEqual(order.map(ActionClassifier.severity), Array(0..<6))
        XCTAssertEqual(Set(ActionClass.allCases), Set(order))
    }

    func testModelCannotLowerClass() {
        let p = Proposal(title: "t", steps: [
            ProposalStep(text: "delete the old table", claimedClass: .routine),
            ProposalStep(text: "read the notes", claimedClass: .deploy),
            ProposalStep(text: "send the report", claimedClass: .editDomainLogic),
        ], risks: [], questions: [])
        XCTAssertEqual(p.effectiveSteps.map(\.effectiveClass), [.irreversible, .deploy, .externalSend])
        XCTAssertEqual(p.overallClass, .irreversible)
    }

    func testOverallClassIsHighest() {
        let p = Proposal(title: "t", steps: [
            ProposalStep(text: "read", claimedClass: .routine),
            ProposalStep(text: "tune", claimedClass: .editSafetyCheck),
        ], risks: [], questions: [])
        XCTAssertEqual(p.overallClass, .editSafetyCheck)
    }

    // MARK: PlannerAgent
    func testSensitiveProfileMakesNoTransportCall() async {
        // Non-https endpoint: any attempted call would give outcome "request-error" with a record.
        let t = OpenRouterTransport(apiKey: "k", model: "m", endpoint: URL(string: "http://example.invalid/x")!)
        let (result, record) = await PlannerAgent(transport: t).propose(intent: "secret", profile: .light, profileSensitive: true)
        XCTAssertEqual(result, .failure(.blockedBySensitiveProfile))
        XCTAssertNil(record)
        // Control: the same transport, non-sensitive, does attempt a call and reports it.
        let (r2, rec2) = await PlannerAgent(transport: t).propose(intent: "x", profile: .light, profileSensitive: false)
        XCTAssertEqual(r2, .failure(.unavailable))
        XCTAssertEqual(rec2?.outcome, "request-error")
    }

    func testPlannerRequestBodyHasSchemaAndIntentButNoKey() throws {
        let key = "sk-test-SECRET-123"
        let req = try PlannerAgent.buildURLRequest(intent: "Please add retries", model: "vendor/m", apiKey: key,
                                                   endpoint: URL(string: "https://example.invalid/x")!)
        let body = String(decoding: req.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("Please add retries"))
        XCTAssertTrue(body.contains("claimedClass"))
        XCTAssertTrue(body.contains("json_schema"))
        XCTAssertTrue(body.contains("editSafetyCheck"))
        XCTAssertTrue(body.contains("max_tokens"))
        XCTAssertFalse(body.contains(key))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
    }

    func testIntentCleanedAndCapped() {
        let cleaned = PlannerAgent.cleanIntent("a\u{0000}b\u{202E}c" + String(repeating: "z", count: 3000))
        XCTAssertLessThanOrEqual(cleaned.unicodeScalars.count, 2000)  // input bounded to 2000 scalars before stripping
        XCTAssertTrue(cleaned.hasPrefix("abc"))
    }

    // MARK: ProposalGate
    func testGateRequestOmitsSummaryWhenSensitive() throws {
        let p = Proposal(title: "SECRET TITLE", steps: [ProposalStep(text: "a", claimedClass: .routine)], risks: [], questions: [])
        let s = ProposalGate.gateRequest(for: p, profile: .light, profileSensitive: true)
        XCTAssertNil(s.summary)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("SECRET TITLE"))
        let n = ProposalGate.gateRequest(for: p, profile: .light, profileSensitive: false)
        XCTAssertEqual(n.summary, "SECRET TITLE")
        XCTAssertEqual(n.changeSize, 1)
        XCTAssertEqual(n.actionClass, .routine)
        XCTAssertEqual(n.agentConfidence, 0.5)
    }

    func testDecideNeverDropsRequiredHuman() {
        let quiet = GateResponse(route: .proceed, needsHuman: false, detailLevel: 0, confidence: 0.99, reason: "fine")
        let profiles: [RiskProfile] = [.light, .strict, RiskProfile(name: "u", extraHumanRequired: [], unsure: true)]
        for cls in ActionClass.allCases {
            let p = Proposal(title: "t", steps: [ProposalStep(text: "read", claimedClass: cls)], risks: [], questions: [])
            for profile in profiles {
                let floorNeeds: Bool
                if case .humanRequired = FloorGate.evaluate(p.overallClass, profile: profile) { floorNeeds = true } else { floorNeeds = false }
                for gate: Result<GateResponse, GateError> in [.failure(.unavailable), .success(quiet)] {
                    let d = ProposalGate.decide(proposal: p, profile: profile, gate: gate)
                    if floorNeeds { XCTAssertTrue(d.needsHuman, "\(cls) \(profile.name)") }
                    if case .failure = gate { XCTAssertTrue(d.needsHuman) }
                }
            }
        }
    }
}
