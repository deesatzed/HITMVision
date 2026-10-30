import XCTest
@testable import HITMCore

final class RuleStoreTests: XCTestCase {
    private var root: URL!
    private let unsure = RiskProfile(name: "u", extraHumanRequired: [], unsure: true)
    private let sensitive = RiskProfile(name: "s", extraHumanRequired: [], sensitive: true)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hitm-rulestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func store() throws -> RuleStore { RuleStore(mind: try MindStore(root: root)) }

    private func rule(_ id: String = "r1", _ family: CommandFamilyID = .readOnlySearch, command: String = "grep",
                      scope: RuleScope = .session("s1"), effect: RuleEffect = .allow) -> Rule {
        Rule(id: id, family: family, command: command, scope: scope, effect: effect, projectID: "p1")
    }

    private func accepted(_ s: RuleStore, _ r: Rule, profile: RiskProfile = .light) throws -> MindRecord {
        let rec = try s.propose(rule: r, author: "agent-1", profile: profile)
        return try s.accept(recordID: rec.id, profile: profile, human: "AB")
    }

    // MARK: propose and accept

    func testProposedRuleIsQuarantinedPolicyAndNotActive() throws {
        let s = try store()
        let rec = try s.propose(rule: rule(), author: "agent-1", profile: .light)
        XCTAssertEqual(rec.kind, .policy)
        XCTAssertEqual(rec.status, .quarantined)
        XCTAssertEqual(try s.activeRules(), [])
        let book = RuleBook(rules: try s.activeRules(), onboardedProjects: ["p1"])
        let ctx = RuleContext(profile: .light, actionClass: .routine, projectID: "p1", folderPath: "/proj", sessionID: "s1")
        if case .allow = book.decide(command: "grep x f", context: ctx) { XCTFail("unapproved rule must not allow") }
    }

    func testNoHumanMeansNoApprovalUnderEveryProfile() throws {
        for profile in [RiskProfile.light, .strict, unsure, sensitive] {
            XCTAssertNil(MindPolicy.approve(kind: .policy, entryID: "x", profile: profile, gate: nil, human: nil), profile.name)
            let s = try store()
            let rec = try s.propose(rule: rule("r-\(profile.name)"), author: "agent-1", profile: profile)
            for blank in [nil, "", "   "] {
                XCTAssertThrowsError(try s.accept(recordID: rec.id, profile: profile, human: blank)) {
                    XCTAssertEqual($0 as? RuleStoreError, .humanApprovalRequired)
                }
            }
            XCTAssertEqual(try s.activeRules(), [])
            try FileManager.default.removeItem(at: root.appendingPathComponent(".hitm"))
        }
    }

    func testAForgedAutoGateApprovalCannotActivateARule() throws {
        let s = try store()
        let rec = try s.propose(rule: rule(), author: "agent-1", profile: .light)
        let forged = Approval(kind: .policy, entryID: rec.id, approver: "auto-gate", isHuman: false)
        XCTAssertThrowsError(try s.mind.accept(id: rec.id, approval: forged)) {
            XCTAssertEqual($0 as? MindError, .illegalTransition)
        }
        XCTAssertEqual(try s.activeRules(), [])
    }

    func testHumanAcceptanceActivatesTheRuleAndSurvivesReopening() throws {
        let s = try store()
        let r = rule(scope: .projectFolder("/proj"))
        _ = try accepted(s, r)
        XCTAssertEqual(try s.activeRules(), [r])
        XCTAssertEqual(try store().activeRules(), [r], "a fresh store over the same files sees it")
    }

    func testRuleDatesAndAllFieldsRoundTripThroughTheStore() throws {
        let s = try store()
        let r = Rule(id: "full", family: .localGit, command: "git", subcommand: "status", scope: .project,
                     effect: .ask, projectID: "p1", enabledForProjects: ["p1", "p2"],
                     expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        _ = try accepted(s, r)
        XCTAssertEqual(try s.activeRules(), [r])
    }

    func testProposeRefusesAnAllowRuleAboveTheFamilyCeiling() throws {
        let s = try store()
        XCTAssertThrowsError(try s.propose(rule: rule("g", .localGit, command: "git", scope: .all), author: "a", profile: .light)) {
            XCTAssertEqual($0 as? RuleStoreError, .aboveCeiling)
        }
        XCTAssertNoThrow(try s.propose(rule: rule("g2", .localGit, command: "git", scope: .all, effect: .ask), author: "a", profile: .light))
    }

    func testProposeRefusesADuplicateOfAnActiveRuleId() throws {
        let s = try store()
        _ = try accepted(s, rule())
        XCTAssertThrowsError(try s.propose(rule: rule(), author: "a", profile: .light)) {
            XCTAssertEqual($0 as? RuleStoreError, .duplicateRuleID)
        }
    }

    // MARK: fail closed

    func testUndecodableOrUnknownBodiesAreIgnoredWhileGoodRulesStay() throws {
        let s = try store()
        let good = rule("good")
        _ = try accepted(s, good)
        let approve = { (rec: MindRecord) in
            try s.mind.accept(id: rec.id, approval: XCTUnwrap(MindPolicy.approve(kind: .policy, entryID: rec.id, profile: .light, gate: nil, human: "AB")))
        }
        let bodies = ["{not json", #"{"id":"x"}"#,
                      #"{"id":"bad","family":"readOnlySearch","command":"grep","scope":{"kind":"galaxy"},"effect":"allow","enabledForProjects":[]}"#,
                      #"{"id":"bad","family":"readOnlySearch","command":"grep","scope":{"kind":"project"},"effect":"deny","enabledForProjects":[]}"#]
        for b in bodies {
            let rec = try s.mind.propose(kind: .policy, title: "bad rule", body: b, tags: ["standing-rule"], author: "agent", sensitive: false)
            _ = try approve(rec)
        }
        XCTAssertEqual(try s.activeRules(), [good])
        XCTAssertEqual(try s.health().untrustedEntryCount, 4, "ignored entries are reported, not silent")
    }

    func testATamperedRuleFileIsIgnored() throws {
        let s = try store()
        let rec = try accepted(s, rule("t"))
        _ = try accepted(s, rule("keep"))
        let child = root.appendingPathComponent(".hitm/entries/\(rec.id).json")
        var text = try String(contentsOf: child, encoding: .utf8)
        text = text.replacingOccurrences(of: "session", with: "all")
        try text.write(to: child, atomically: true, encoding: .utf8)
        XCTAssertEqual(try s.activeRules().map(\.id), ["keep"])
    }

    // MARK: widen and revoke

    func testWideningIsAProposalThatNeedsFreshApprovalAndSupersedesTheOld() throws {
        let s = try store()
        let old = try accepted(s, rule("w", scope: .session("s1")))
        let wide = try s.widen(ruleID: "w", to: .project, author: "agent-2", profile: .light)
        XCTAssertEqual(wide.status, .quarantined)
        XCTAssertEqual(wide.supersedes, old.id)
        XCTAssertEqual(try s.activeRules().map(\.scope), [.session("s1")], "still the old, narrow rule")
        XCTAssertThrowsError(try s.accept(recordID: wide.id, profile: .light, human: nil))
        XCTAssertEqual(try s.activeRules().map(\.scope), [.session("s1")])
        _ = try s.accept(recordID: wide.id, profile: .light, human: "AB")
        XCTAssertEqual(try s.activeRules().map(\.scope), [.project])
        XCTAssertEqual(s.mind.record(id: old.id)?.status, .superseded)
    }

    func testWidenRefusesSameOrNarrowerScopeAboveCeilingOrUnknownRule() throws {
        let s = try store()
        _ = try accepted(s, rule("a", scope: .project))
        _ = try accepted(s, rule("g", .localGit, command: "git", scope: .project))
        for narrower in [RuleScope.project, .projectFolder("/proj"), .session("s")] {
            XCTAssertThrowsError(try s.widen(ruleID: "a", to: narrower, author: "x", profile: .light)) {
                XCTAssertEqual($0 as? RuleStoreError, .notWider)
            }
        }
        XCTAssertThrowsError(try s.widen(ruleID: "g", to: .all, author: "x", profile: .light)) {
            XCTAssertEqual($0 as? RuleStoreError, .aboveCeiling)
        }
        XCTAssertThrowsError(try s.widen(ruleID: "nope", to: .all, author: "x", profile: .light)) {
            XCTAssertEqual($0 as? RuleStoreError, .unknownRule)
        }
    }

    func testRevokedRuleNoLongerApplies() throws {
        let s = try store()
        let rec = try accepted(s, rule("v", scope: .project))
        let book = { RuleBook(rules: try s.activeRules(), onboardedProjects: ["p1"]) }
        let ctx = RuleContext(profile: .light, actionClass: .routine, projectID: "p1", folderPath: "/proj", sessionID: nil)
        XCTAssertEqual(try book().decide(command: "grep x f", context: ctx), .allow(ruleID: "v"))
        try s.revoke(ruleID: "v", by: "AB")
        XCTAssertEqual(s.mind.record(id: rec.id)?.status, .expired)
        XCTAssertEqual(try s.activeRules(), [])
        if case .ask = try book().decide(command: "grep x f", context: ctx) {} else { XCTFail("revoked rule must ask") }
        XCTAssertThrowsError(try s.revoke(ruleID: "v", by: "AB")) { XCTAssertEqual($0 as? RuleStoreError, .unknownRule) }
    }

    // MARK: sensitivity

    func testSensitiveRulesNeverReachAHostedModelSlice() throws {
        let s = try store()
        for (id, profile) in [("light-rule", RiskProfile.light), ("strict-rule", .strict), ("unsure-rule", unsure), ("sens-rule", sensitive)] {
            _ = try accepted(s, rule(id), profile: profile)
        }
        func titles(_ d: MindDestination) throws -> Set<String> {
            Set(try s.mind.slices(role: "planner", kinds: [.policy], tags: [], budgetCharacters: 1_000_000, destination: d).map(\.title))
        }
        XCTAssertEqual(try titles(.local).count, 4)
        let hosted = try titles(.hostedModel)
        XCTAssertEqual(hosted.count, 2, "only the rules written under light and strict profiles are not sensitive")
        XCTAssertFalse(hosted.contains { $0.contains("sens-rule") || $0.contains("unsure-rule") })
    }

    func testWideningASensitiveRuleStaysSensitive() throws {
        let s = try store()
        _ = try accepted(s, rule("sr", scope: .session("s1")), profile: sensitive)
        let wide = try s.widen(ruleID: "sr", to: .project, author: "x", profile: .light)
        XCTAssertTrue(wide.sensitive)
    }

    // MARK: review round

    private func corrupt(_ rec: MindRecord) throws {
        let child = root.appendingPathComponent(".hitm/entries/\(rec.id).json")
        var text = try String(contentsOf: child, encoding: .utf8)
        text += " "
        try text.write(to: child, atomically: true, encoding: .utf8)
    }

    private func ctx1() -> RuleContext {
        RuleContext(profile: .light, actionClass: .routine, projectID: "p1", folderPath: "/proj", sessionID: "s1")
    }

    func testProposingAnIdTwiceIsRefusedWhetherQuarantinedOrAccepted() throws {
        let s = try store()
        _ = try s.propose(rule: rule("r1"), author: "a", profile: .light)
        XCTAssertThrowsError(try s.propose(rule: rule("r1"), author: "a", profile: .light)) {
            XCTAssertEqual($0 as? RuleStoreError, .duplicateRuleID)
        }
        let rec = try s.propose(rule: rule("r2"), author: "a", profile: .light)
        _ = try s.accept(recordID: rec.id, profile: .light, human: "AB")
        XCTAssertThrowsError(try s.propose(rule: rule("r2"), author: "a", profile: .light)) {
            XCTAssertEqual($0 as? RuleStoreError, .duplicateRuleID)
        }
    }

    func testConcurrentProposalsOfOneIdLetExactlyOneThrough() throws {
        let s = try store()
        let lock = NSLock()
        var successes = 0
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            if (try? s.propose(rule: rule("race"), author: "a", profile: .light)) != nil {
                lock.lock(); successes += 1; lock.unlock()
            }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(mindPolicyRecords(s).count, 1)
    }

    private func mindPolicyRecords(_ s: RuleStore) -> [MindRecord] { s.mind.records.filter { $0.kind == .policy } }

    func testRevokeExpiresEveryActiveEntryForTheRuleId() throws {
        let s = try store()
        // Two accepted entries for one id cannot be made through the store any more; forge them in the mind.
        let r = rule("w", scope: .project)
        let body = try RuleStore.encode(r)
        for _ in 0..<2 {
            let rec = try s.mind.propose(kind: .policy, title: "Standing rule w", body: body,
                                         tags: [RuleStore.tag, RuleStore.ridTag("w")], author: "agent", sensitive: false)
            _ = try s.mind.accept(id: rec.id, approval: XCTUnwrap(MindPolicy.approve(kind: .policy, entryID: rec.id, profile: .light, gate: nil, human: "AB")))
        }
        XCTAssertEqual(mindPolicyRecords(s).filter { $0.status == .accepted }.count, 2)
        try s.revoke(ruleID: "w", by: "AB")
        XCTAssertEqual(mindPolicyRecords(s).filter { $0.status == .accepted }.count, 0)
        XCTAssertEqual(try s.activeRules(), [])
        let book = try s.ruleBook(onboardedProjects: ["p1"])
        if case .allow = book.decide(command: "grep x f", context: ctx1()) { XCTFail("revoked rule must not allow") }
    }

    func testWidenRefusesWhileAWideningOfTheSameRuleIsPending() throws {
        let s = try store()
        _ = try accepted(s, rule("w", scope: .session("s1")))
        let w1 = try s.widen(ruleID: "w", to: .project, author: "x", profile: .light)
        XCTAssertThrowsError(try s.widen(ruleID: "w", to: .all, author: "y", profile: .light)) {
            XCTAssertEqual($0 as? RuleStoreError, .changePending)
        }
        _ = try s.accept(recordID: w1.id, profile: .light, human: "AB")
        XCTAssertNoThrow(try s.widen(ruleID: "w", to: .all, author: "y", profile: .light), "allowed again once the first is decided")
    }

    func testRevokingAnAskRuleNeedsANamedHumanWhoIsNotTheAuthorButAllowRulesStayOpen() throws {
        let s = try store()
        let askRec = try s.propose(rule: rule("ask", scope: .project, effect: .ask), author: "AB", profile: .light)
        _ = try s.accept(recordID: askRec.id, profile: .light, human: "CD")
        for blank in ["", "  "] {
            XCTAssertThrowsError(try s.revoke(ruleID: "ask", by: blank)) { XCTAssertEqual($0 as? RuleStoreError, .humanApprovalRequired) }
        }
        XCTAssertThrowsError(try s.revoke(ruleID: "ask", by: " ab ")) { XCTAssertEqual($0 as? RuleStoreError, .approverIsAuthor) }
        XCTAssertEqual(try s.activeRules().count, 1, "the ask rule is still in force")
        try s.revoke(ruleID: "ask", by: "EF")
        XCTAssertEqual(try s.activeRules(), [])
        // allow rule: tightening policy, so the author (or an agent name) may revoke it
        let allowRec = try s.propose(rule: rule("allow", scope: .project), author: "AB", profile: .light)
        _ = try s.accept(recordID: allowRec.id, profile: .light, human: "CD")
        XCTAssertNoThrow(try s.revoke(ruleID: "allow", by: "AB"))
    }

    func testRevokingAnUnverifiableRuleIsTreatedAsAnAskRule() throws {
        let s = try store()
        let rec = try s.propose(rule: rule("u", scope: .project), author: "AB", profile: .light)
        _ = try s.accept(recordID: rec.id, profile: .light, human: "CD")
        try corrupt(rec)
        XCTAssertThrowsError(try s.revoke(ruleID: "u", by: "AB")) { XCTAssertEqual($0 as? RuleStoreError, .approverIsAuthor) }
        XCTAssertNoThrow(try s.revoke(ruleID: "u", by: "EF"))
    }

    func testRevokeStillWorksWhenAnEntryCannotBeVerified() throws {
        let s = try store()
        let rec = try accepted(s, rule("v", scope: .project))
        try corrupt(rec)
        try s.revoke(ruleID: "v", by: "AB")
        XCTAssertEqual(s.mind.record(id: rec.id)?.status, .expired)
    }

    func testACorruptAskRuleMakesEverythingAskEvenWithABroaderAllow() throws {
        let s = try store()
        let askRec = try accepted(s, rule("ask", scope: .session("s1"), effect: .ask))
        _ = try accepted(s, rule("allow", scope: .project))
        let before = try s.ruleBook(onboardedProjects: ["p1"])
        XCTAssertEqual(before.decide(command: "grep x f", context: ctx1()), .ask(reason: "Your standing rule 'ask' says to always ask for this kind of command."))
        try corrupt(askRec)
        XCTAssertEqual(try s.health().untrustedEntryCount, 1)
        let book = try s.ruleBook(onboardedProjects: ["p1"])
        XCTAssertEqual(book.decide(command: "grep x f", context: ctx1()), .ask(reason: RuleBook.unverifiedReason))
        // the unprotected path (decoded rules only) would have allowed: that is the hole this closes
        let naive = RuleBook(rules: try s.activeRules(), onboardedProjects: ["p1"])
        XCTAssertEqual(naive.decide(command: "grep x f", context: ctx1()), .allow(ruleID: "allow"))
    }

    func testACorruptAllowRuleAlsoMakesEverythingAsk() throws {
        let s = try store()
        let rec = try accepted(s, rule("allowA", scope: .project))
        _ = try accepted(s, rule("allowB", command: "head", scope: .project))
        try corrupt(rec)
        let book = try s.ruleBook(onboardedProjects: ["p1"])
        XCTAssertEqual(book.decide(command: "head x", context: ctx1()), .ask(reason: RuleBook.unverifiedReason))
    }

    func testAHealthyStoreStillAllows() throws {
        let s = try store()
        _ = try accepted(s, rule("ok", scope: .project))
        XCTAssertEqual(try s.health().untrustedEntryCount, 0)
        let book = try s.ruleBook(onboardedProjects: ["p1"])
        XCTAssertEqual(book.decide(command: "grep x f", context: ctx1()), .allow(ruleID: "ok"))
    }

    func testApproverMayNotBeTheAuthor() throws {
        let s = try store()
        let rec = try s.propose(rule: rule(), author: "AB", profile: .light)
        for name in ["AB", " ab ", "Ab"] {
            XCTAssertThrowsError(try s.accept(recordID: rec.id, profile: .light, human: name)) {
                XCTAssertEqual($0 as? RuleStoreError, .approverIsAuthor)
            }
        }
        XCTAssertEqual(try s.activeRules(), [])
        _ = try s.accept(recordID: rec.id, profile: .light, human: "CD")
        XCTAssertEqual(try s.activeRules().count, 1)
    }

    func testRulesThatCanNeverApplyAreRefused() throws {
        let s = try store()
        let noProject = Rule(id: "np", family: .readOnlySearch, command: "grep", scope: .session("s1"), effect: .allow, projectID: nil)
        _ = try accepted(s, noProject)
        XCTAssertThrowsError(try s.widen(ruleID: "np", to: .project, author: "x", profile: .light)) {
            XCTAssertEqual($0 as? RuleStoreError, .missingProjectID)
        }
        XCTAssertThrowsError(try s.widen(ruleID: "np", to: .projectFolder("/p"), author: "x", profile: .light))
        XCTAssertNoThrow(try s.widen(ruleID: "np", to: .all, author: "x", profile: .light))
        let bad = Rule(id: "bad", family: .readOnlySearch, command: "grep", scope: .project, effect: .allow, projectID: nil)
        XCTAssertThrowsError(try s.propose(rule: bad, author: "x", profile: .light)) {
            XCTAssertEqual($0 as? RuleStoreError, .missingProjectID)
        }
    }
}
