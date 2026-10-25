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
    func classes(_ cases: [String], _ cls: ActionClass, file: StaticString = #filePath, line: UInt = #line) {
        for t in cases { XCTAssertEqual(ActionClassifier.minimumClass(forStepText: t), cls, t, file: file, line: line) }
    }

    func testIrreversibleMatches() {
        classes(["Delete the old table", "deletion of rows", "erase the disk", "purge the cache", "destroy the cache",
                 "wipe the disk", "truncate the table", "nuke it", "obliterate history", "overwrite the config",
                 "run rm -rf build", "force push the branch", "git push --force origin x", "git reset --hard HEAD",
                 "drop table users", "DROP DATABASE prod", "drop schema x", "drop column a", "drop collection c",
                 "remove permanently the logs", "permanently remove the logs"], .irreversible)
    }

    func testIrreversibleBypassProbes() {
        classes(["del ete the rows", "d e l e t e the rows", "ｄｅｌｅｔｅ the rows", "force-push it", "dr op table users"], .irreversible)
    }

    func testIrreversibleNonMatches() {
        classes(["remove the folder", "add a dropdown menu", "fix the backdrop", "undelete the file", "drop the index"], .routine)
    }

    func testDeployMatches() {
        classes(["deploy to staging", "go live on Monday", "roll out the change", "start the rollout", "push to prod",
                 "push to main", "ship to customers", "release to users", "publish to npm", "publish the package",
                 "d e p l o y it"], .deploy)
    }

    func testDeployNonMatches() {
        classes(["write release notes", "check the released lock", "release version 2"], .routine)
    }

    func testExternalSendMatches() {
        classes(["upload the file to a third-party host", "send data to a vendor", "transmit to the cloud",
                 "post results to the remote server", "email the report to a partner", "sync with the cloud",
                 "share it with an external team", "export to https://x.example", "forward to http://x",
                 "curl the endpoint", "send a request to the api", "mail it to an external address",
                 "call a webhook", "exfiltrate the data", "use a third-party service", "use a third party service",
                 "send the user data to our server", "email the report to the client", "send the report",
                 "upload the data", "export the customer database", "share the logs with support",
                 "upload the logs to an external service", "send the customer database to the vendor",
                 "copy the backup off the machine", "forward the secrets", "sync the patient records"], .externalSend)
    }

    func testExternalSendNonMatches() {
        classes(["telemetry logging locally", "send the user to login", "fix the sender field",
                 "email validation", "upload progress bar", "use an external service", "send the user to the login page",
                 "add telemetry logging locally", "post a comment in the code review", "export button styling"], .routine)
    }

    func testSafetyMatches() {
        classes(["change an assertion", "widen tolerance", "edit permission checks", "store the credential",
                 "rotate the password", "fix authentication", "fix authorization", "update the safety check",
                 "adjust the bounds check", "tune the rate limit", "edit the limit check", "move the threshold",
                 "edit the guard", "disable the check", "skip the test", "bypass validation", "relax the tolerance",
                 "loosen the limit", "widen the threshold", "ignore the assertion", "remove the guard"], .editSafetyCheck)
    }

    func testSafetyNonMatches() {
        classes(["credit the author", "the authority page", "limited scope", "unlimited plan", "change the delimiter",
                 "guardian name field", "improve validation", "remove the folder"], .routine)
    }

    func testDomainLogicMatches() {
        classes(["update the business rule", "rewrite core logic", "fix the calculation", "adjust pricing",
                 "tune the algorithm"], .editDomainLogic)
    }

    func testRoutineAndCaseInsensitivity() {
        classes(["read the README", "rename a local variable"], .routine)
        XCTAssertEqual(ActionClassifier.minimumClass(forStepText: "DEPLOY NOW"), .deploy)
        XCTAssertEqual(ActionClassifier.minimumClass(forStepText: "Fix The CALCULATION"), .editDomainLogic)
    }

    func testKnownUncaughtSynonymsAreDocumented() {
        // ACCEPTED LIMITS: these currently classify routine. A future change must be deliberate.
        classes(["eliminate the records", "get rid of the table", "make it vanish", "dеlete the rows" /* Cyrillic e */], .routine)
    }

    func testClassifierPicksHighestMatchingRule() {
        XCTAssertEqual(ActionClassifier.minimumClass(forStepText: "email the pricing and delete it"), .irreversible)
        XCTAssertEqual(ActionClassifier.minimumClass(forStepText: "email the pricing to a vendor"), .externalSend)
    }

    func testWholeProposalIsClassified() {
        let routineStep = [ProposalStep(text: "read the notes", claimedClass: .routine)]
        XCTAssertEqual(Proposal(title: "Delete production DB", steps: routineStep, risks: [], questions: []).overallClass, .irreversible)
        XCTAssertEqual(Proposal(title: "t", steps: routineStep, risks: ["could deploy broken code"], questions: []).overallClass, .deploy)
        XCTAssertEqual(Proposal(title: "t", steps: routineStep, risks: [], questions: ["Can we skip the test?"]).overallClass, .editSafetyCheck)
        XCTAssertEqual(Proposal(title: "t", steps: routineStep, risks: [], questions: []).overallClass, .routine)
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
            ProposalStep(text: "upload the report to a vendor", claimedClass: .editDomainLogic),
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
        let sens = RiskProfile(name: "s", extraHumanRequired: [], sensitive: true)
        let (result, record) = await PlannerAgent(transport: t).propose(intent: "secret", profile: sens)
        XCTAssertEqual(result, .failure(.blockedBySensitiveProfile))
        XCTAssertNil(record)
        // Control: the same transport, non-sensitive, does attempt a call and reports it.
        let (r2, rec2) = await PlannerAgent(transport: t).propose(intent: "x", profile: .light)
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
        let s = ProposalGate.gateRequest(for: p, profile: RiskProfile(name: "s", extraHumanRequired: [], sensitive: true))
        XCTAssertNil(s.summary)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("SECRET TITLE"))
        let n = ProposalGate.gateRequest(for: p, profile: .light)
        XCTAssertEqual(n.summary, "SECRET TITLE")
        XCTAssertEqual(n.changeSize, 1)
        XCTAssertEqual(n.actionClass, .routine)
        XCTAssertNil(n.agentConfidence)
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

    // MARK: sensitivity from profile, adapter seam, confidence
    func testSensitiveAndUnsureProfilesBlockWithoutTransportCall() async {
        let t = OpenRouterTransport(apiKey: "k", model: "m", endpoint: URL(string: "http://example.invalid/x")!)
        for profile in [RiskProfile(name: "s", extraHumanRequired: [], sensitive: true),
                        RiskProfile(name: "u", extraHumanRequired: [], unsure: true)] {
            let (r, rec) = await PlannerAgent(transport: t).propose(intent: "x", profile: profile)
            XCTAssertEqual(r, .failure(.blockedBySensitiveProfile))
            XCTAssertNil(rec)
        }
    }

    func testGateRequestUsesProfileSensitivity() {
        let p = Proposal(title: "SECRET", steps: [ProposalStep(text: "a", claimedClass: .routine)], risks: [], questions: [])
        XCTAssertNil(ProposalGate.gateRequest(for: p, profile: RiskProfile(name: "s", extraHumanRequired: [], sensitive: true)).summary)
        XCTAssertNil(ProposalGate.gateRequest(for: p, profile: RiskProfile(name: "u", extraHumanRequired: [], unsure: true)).summary)
    }

    func testPlannerConformsToAgentAdapter() {
        let t = OpenRouterTransport(apiKey: "k", model: "m")
        let adapter: any AgentAdapter = PlannerAgent(transport: t)
        XCTAssertEqual(adapter.role, "Planner")
    }

    func testNilConfidenceOmitsKeyAndPromptSaysNotReported() throws {
        let p = Proposal(title: "t", steps: [ProposalStep(text: "a", claimedClass: .routine)], risks: [], questions: [])
        let json = String(decoding: try JSONEncoder().encode(ProposalGate.gateRequest(for: p, profile: .light)), as: UTF8.self)
        XCTAssertFalse(json.contains("agentConfidence"))
        let supplied = String(decoding: try JSONEncoder().encode(ProposalGate.gateRequest(for: p, profile: .light, agentConfidence: 0.7)), as: UTF8.self)
        XCTAssertTrue(supplied.contains("agentConfidence"))
        XCTAssertTrue(OpenRouterGateClient.systemPrompt.contains("not reported"))
    }
}
