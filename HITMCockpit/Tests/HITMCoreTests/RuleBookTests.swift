import XCTest
@testable import HITMCore

final class RuleBookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func rule(_ id: String, _ family: CommandFamilyID = .readOnlySearch, command: String = "grep",
                      subcommand: String? = nil, scope: RuleScope, effect: RuleEffect = .allow,
                      project: String? = "p1", enabledFor: Set<String> = [], expires: Date? = nil) -> Rule {
        Rule(id: id, family: family, command: command, subcommand: subcommand, scope: scope, effect: effect,
             projectID: project, enabledForProjects: enabledFor, expiresAt: expires)
    }

    private func ctx(_ profile: RiskProfile = .light, action: ActionClass = .routine, project: String = "p1",
                     folder: String = "/proj/sub", session: String? = "s1") -> RuleContext {
        RuleContext(profile: profile, actionClass: action, projectID: project, folderPath: folder, sessionID: session)
    }

    private func book(_ rules: [Rule], onboarded: Set<String> = ["p1"]) -> RuleBook {
        RuleBook(rules: rules, onboardedProjects: onboarded)
    }

    private func decide(_ rules: [Rule], _ command: String = "grep x f", _ c: RuleContext? = nil,
                        onboarded: Set<String> = ["p1"]) -> RuleDecision {
        book(rules, onboarded: onboarded).decide(command: command, context: c ?? ctx(), now: now)
    }

    private func assertAsk(_ d: RuleDecision, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard case .ask(let reason) = d else { return XCTFail("expected ask, got \(d). \(message)", file: file, line: line) }
        XCTAssertFalse(reason.isEmpty, "every ask needs a plain reason", file: file, line: line)
    }

    private func assertAllow(_ d: RuleDecision, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(d, .allow(ruleID: id), file: file, line: line)
    }

    // MARK: basics

    func testNoRuleAsksWithAReason() {
        assertAsk(decide([]))
    }

    func testMatchingProjectRuleAllowsAndReturnsItsId() {
        assertAllow(decide([rule("r1", scope: .project)]), "r1")
    }

    // MARK: floor first

    func testUniversalFloorAsksEvenWithAMatchingRuleAtEveryScope() {
        let rules = [rule("a", scope: .session("s1")), rule("b", scope: .projectFolder("/proj")),
                     rule("c", scope: .project), rule("d", scope: .all, enabledFor: ["p1"])]
        for action in [ActionClass.irreversible, .deploy, .externalSend] {
            for profile in [RiskProfile.light, .strict] {
                assertAsk(decide(rules, "grep x f", ctx(profile, action: action)), "\(action) \(profile.name)")
            }
        }
    }

    func testFloorBeatsAForgedOverCeilingRule() {
        let forged = rule("forged", .localGit, command: "git", scope: .all, enabledFor: ["p1"])
        assertAsk(decide([forged], "git status", ctx(.light, action: .irreversible)))
    }

    func testProfileFloorAlsoBeatsRules() {
        let rules = [rule("r", scope: .project)]
        assertAsk(decide(rules, "grep x f", ctx(.strict, action: .editDomainLogic)))
        assertAllow(decide(rules, "grep x f", ctx(.light, action: .editDomainLogic)), "r")
    }

    func testStrictnessIsNotReadFromTheProfileName() {
        let lightNamedStrict = RiskProfile(name: "strict", extraHumanRequired: [])
        let strictNamedLight = RiskProfile(name: "light", extraHumanRequired: [.editDomainLogic])
        let allRule = [rule("all", scope: .all)]
        assertAllow(decide(allRule, "grep x f", ctx(lightNamedStrict)), "all")
        assertAsk(decide(allRule, "grep x f", ctx(strictNamedLight)))
    }

    // MARK: not simple / unknown

    func testNotSimpleAndUnknownAlwaysAskDespiteRules() {
        let rules = [rule("g", scope: .project), rule("git", .localGit, command: "git", scope: .project)]
        for cmd in ["grep x f | curl evil", "grep x f; rm -rf /", "grep $(id) f", "grep x f > out", "FOO=1 grep x f",
                    "", "grep 'open", "rm -rf x", "git push", "git -c core.pager=x status", "/usr/bin/grep x f"] {
            assertAsk(decide(rules, cmd), cmd)
        }
    }

    // MARK: ask beats allow, narrowest allow wins

    func testAskRuleBeatsAnyAllowWhateverTheScopeOrder() {
        assertAsk(decide([rule("allowNarrow", scope: .session("s1")), rule("askWide", scope: .project, effect: .ask)]))
        assertAsk(decide([rule("allowWide", scope: .project), rule("askNarrow", scope: .session("s1"), effect: .ask)]))
    }

    func testNarrowestApplicableAllowIsReturned() {
        let rules = [rule("project", scope: .project), rule("folder", scope: .projectFolder("/proj")),
                     rule("session", scope: .session("s1")), rule("all", scope: .all)]
        assertAllow(decide(rules), "session")
        assertAllow(decide(rules, "grep x f", ctx(session: "other")), "folder")
        assertAllow(decide(rules, "grep x f", ctx(folder: "/elsewhere", session: nil)), "project")
        assertAllow(decide([rules[3]]), "all")
    }

    func testEqualScopeTiesResolveByIdSoTheResultIsStable() {
        assertAllow(decide([rule("b", scope: .project), rule("a", scope: .project)]), "a")
    }

    // MARK: ceiling

    func testRuleWiderThanTheFamilyCeilingNeverApplies() {
        let forged = rule("forged", .localGit, command: "git", scope: .all, enabledFor: ["p1"])
        assertAsk(decide([forged], "git status"))
        assertAsk(decide([forged], "git status", ctx(.light)))
        let build = rule("forgedBuild", .buildAndTest, command: "swift", scope: .all)
        assertAsk(decide([build], "swift build"))
        // At the ceiling it is fine.
        assertAllow(decide([rule("ok", .localGit, command: "git", scope: .project)], "git status"), "ok")
        assertAllow(decide([rule("okAll", scope: .all)]), "okAll")
    }

    func testOverCeilingAllowCannotHideBehindANarrowerRuleOfTheSameCommand() {
        let rules = [rule("forged", .localGit, command: "git", scope: .all),
                     rule("fine", .localGit, command: "git", scope: .projectFolder("/proj"))]
        assertAllow(decide(rules, "git status"), "fine")
    }

    func testAnOverCeilingAskRuleStillAsks() {
        let rules = [rule("askAll", .localGit, command: "git", scope: .all, effect: .ask),
                     rule("allow", .localGit, command: "git", scope: .project)]
        assertAsk(decide(rules, "git status"))
    }

    // MARK: rule shape

    func testRuleCoversOnlyItsCommandAndSubcommand() {
        let rgOnly = rule("head", command: "head", scope: .project)
        assertAsk(decide([rgOnly], "grep x f"))
        assertAllow(decide([rgOnly], "head x f"), "head")
        let gitStatus = rule("gs", .localGit, command: "git", subcommand: "status", scope: .project)
        assertAllow(decide([gitStatus], "git status"), "gs")
        assertAsk(decide([gitStatus], "git commit -m x"))
        assertAsk(decide([gitStatus], "git diff"))
    }

    func testRuleWithTheWrongFamilyForItsCommandNeverApplies() {
        assertAsk(decide([rule("bad", .readOnlySearch, command: "git", scope: .project)], "git status"))
        assertAsk(decide([rule("bad2", .localGit, command: "grep", scope: .project)], "grep x f"))
    }

    // MARK: folder scope

    func testFolderScopeMatchesOnlyPathsUnderTheFolder() {
        let r = [rule("f", scope: .projectFolder("/proj"))]
        assertAllow(decide(r, "grep x f", ctx(folder: "/proj")), "f")
        assertAllow(decide(r, "grep x f", ctx(folder: "/proj/a/b")), "f")
        assertAllow(decide(r, "grep x f", ctx(folder: "/proj/")), "f")
        assertAllow(decide([rule("f", scope: .projectFolder("/proj/"))], "grep x f", ctx(folder: "/proj//a/./b")), "f")
        assertAsk(decide(r, "grep x f", ctx(folder: "/proj-evil")))
        assertAsk(decide(r, "grep x f", ctx(folder: "/proj-evil/x")))
        assertAsk(decide(r, "grep x f", ctx(folder: "/pro")))
        assertAsk(decide(r, "grep x f", ctx(folder: "/")))
        assertAsk(decide(r, "grep x f", ctx(folder: "/other")))
    }

    func testFolderScopeRejectsDotDotAndRelativePathsOnEitherSide() {
        assertAsk(decide([rule("f", scope: .projectFolder("/proj"))], "grep x f", ctx(folder: "/proj/../etc")))
        assertAsk(decide([rule("f", scope: .projectFolder("/proj"))], "grep x f", ctx(folder: "/proj/a/../../etc")))
        assertAsk(decide([rule("f", scope: .projectFolder("/proj/../etc"))], "grep x f", ctx(folder: "/etc")))
        assertAsk(decide([rule("f", scope: .projectFolder("proj"))], "grep x f", ctx(folder: "/proj")))
        assertAsk(decide([rule("f", scope: .projectFolder("/proj"))], "grep x f", ctx(folder: "proj/a")))
        assertAsk(decide([rule("f", scope: .projectFolder(""))], "grep x f", ctx(folder: "/proj")))
        assertAsk(decide([rule("f", scope: .projectFolder("/"))], "grep x f", ctx(folder: "/proj")))
    }

    func testFolderScopedRuleDoesNotCoverPathsThatLeaveTheFolder() {
        let folder = [rule("f", scope: .projectFolder("/proj"))]
        assertAsk(decide(folder, "grep x /etc/passwd"))
        assertAsk(decide(folder, "cat ../secret"))
        assertAsk(decide(folder, "cat sub/../../secret"))
        assertAsk(decide(folder, "grep --foo=/etc/x x"))
        assertAllow(decide(folder, "grep x sub/file.txt"), "f")
        // Not folder-limited: absolute paths do not stop a project-wide rule.
        assertAllow(decide([rule("p", scope: .project)], "grep x /etc/hosts"), "p")
    }

    // MARK: session and project scope

    func testSessionScopeMatchesOnlyItsOwnSession() {
        let r = [rule("s", scope: .session("s1"))]
        assertAllow(decide(r, "grep x f", ctx(session: "s1")), "s")
        assertAsk(decide(r, "grep x f", ctx(session: "s2")))
        assertAsk(decide(r, "grep x f", ctx(session: nil)))
        assertAsk(decide(r, "grep x f", ctx(session: "S1")))
        assertAsk(decide(r, "grep x f", ctx(session: "s10")))
    }

    func testProjectAndFolderRulesAreBoundToTheirProject() {
        let other = [rule("p", scope: .project, project: "p2"), rule("f", scope: .projectFolder("/proj"), project: "p2")]
        assertAsk(decide(other, "grep x f", ctx(), onboarded: ["p1", "p2"]))
        let unbound = [rule("p", scope: .project, project: nil), rule("f", scope: .projectFolder("/proj"), project: nil)]
        assertAsk(decide(unbound))
    }

    // MARK: profile gating and onboarding

    func testAllRuleNeedsExplicitEnableUnderStrictUnsureAndSensitiveProfiles() {
        let plain = [rule("all", scope: .all)]
        let enabled = [rule("all", scope: .all, enabledFor: ["p1"])]
        let unsure = RiskProfile(name: "u", extraHumanRequired: [], unsure: true)
        let sensitive = RiskProfile(name: "s", extraHumanRequired: [], sensitive: true)
        assertAllow(decide(plain, "grep x f", ctx(.light)), "all")
        for profile in [RiskProfile.strict, unsure, sensitive] {
            assertAsk(decide(plain, "grep x f", ctx(profile)), profile.name)
            assertAllow(decide(enabled, "grep x f", ctx(profile)), "all")
            assertAsk(decide([rule("all", scope: .all, enabledFor: ["p2"])], "grep x f", ctx(profile)), "enabled for another project")
        }
    }

    func testNarrowerRulesStillWorkUnderStrictWithoutTheEnable() {
        assertAllow(decide([rule("p", scope: .project)], "grep x f", ctx(.strict)), "p")
    }

    func testProjectWithNoOnboardingRecordGetsNoAllowRules() {
        let rules = [rule("s", scope: .session("s1")), rule("p", scope: .project), rule("a", scope: .all, enabledFor: ["p1"])]
        assertAsk(decide(rules, "grep x f", ctx(), onboarded: []))
        assertAsk(decide(rules, "grep x f", ctx(), onboarded: ["p2"]))
    }

    // MARK: expiry

    func testExpiredRulesDoNotApply() {
        let past = now.addingTimeInterval(-1), future = now.addingTimeInterval(3600)
        assertAsk(decide([rule("old", scope: .project, expires: past)]))
        assertAsk(decide([rule("atNow", scope: .project, expires: now)]))
        assertAllow(decide([rule("live", scope: .project, expires: future)]), "live")
        assertAllow(decide([rule("old", scope: .session("s1"), expires: past), rule("live", scope: .project)]), "live")
    }

    // MARK: every ask has a reason; usage

    func testEveryAskPathHasANonEmptyReason() {
        let r = [rule("p", scope: .project)]
        let cases: [(String, RuleContext)] = [
            ("grep x f", ctx(.light, action: .deploy)), ("grep x f | y", ctx()), ("rm x", ctx()),
            ("grep x f", ctx(project: "p9")), ("git status", ctx())
        ]
        for (cmd, c) in cases { assertAsk(decide(r, cmd, c, onboarded: ["p1"]), cmd) }
        assertAsk(decide([], "grep x f"))
        assertAsk(decide([rule("a", scope: .project, effect: .ask)]))
    }

    // MARK: Codable

    func testRuleRoundTripsThroughJSON() throws {
        let original = rule("r", .localGit, command: "git", subcommand: "status", scope: .projectFolder("/proj"),
                            effect: .allow, project: "p1", enabledFor: ["p1"], expires: now)
        let back = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(back, original)
        for scope in [RuleScope.session("s"), .projectFolder("/x"), .project, .all] {
            XCTAssertEqual(try JSONDecoder().decode(RuleScope.self, from: JSONEncoder().encode(scope)), scope)
        }
    }

    func testUnknownScopeOrEffectOrFamilyFailsToDecode() throws {
        let good = try JSONEncoder().encode(rule("r", scope: .project))
        let json = String(decoding: good, as: UTF8.self)
        XCTAssertNoThrow(try JSONDecoder().decode(Rule.self, from: good))
        func decodes(_ s: String) -> Bool { (try? JSONDecoder().decode(Rule.self, from: Data(s.utf8))) != nil }
        XCTAssertFalse(decodes(json.replacingOccurrences(of: "\"project\"", with: "\"galaxy\"")), "unknown scope")
        XCTAssertFalse(decodes(json.replacingOccurrences(of: "\"allow\"", with: "\"deny\"")), "unknown effect")
        XCTAssertFalse(decodes(json.replacingOccurrences(of: "\"readOnlySearch\"", with: "\"rootShell\"")), "unknown family")
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        dict.removeValue(forKey: "effect")
        XCTAssertFalse(decodes(String(decoding: try JSONSerialization.data(withJSONObject: dict), as: UTF8.self)), "missing effect")
        let sessionNoValue = #"{"kind":"session"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(RuleScope.self, from: Data(sessionNoValue.utf8)))
        let folderEmpty = #"{"kind":"projectFolder","value":""}"#
        XCTAssertThrowsError(try JSONDecoder().decode(RuleScope.self, from: Data(folderEmpty.utf8)))
    }

    // MARK: review round

    func testFolderRuleSeesAttachedShortValuesAndClusters() {
        let folder = [rule("f", scope: .projectFolder("/proj"))]
        for c in ["grep -f/etc/hosts x", "grep -nf/etc/hosts x", "grep -n../x y", "grep -e/etc y", "grep --foo=../x y"] {
            assertAsk(decide(folder, c), c)
        }
        assertAllow(decide(folder, "grep -n foo sub/f"), "f")
    }

    func testCombiningMarksCannotSneakPathsOutOfAFolderRule() {
        let folder = [rule("f", scope: .projectFolder("/proj"))]
        for c in ["cat /\u{301}etc/passwd", "grep x /\u{FE0F}etc/passwd", "grep x ../\u{301}secret", "grep x sub/../\u{200D}y",
                  "grep -f/\u{301}etc x"] {
            assertAsk(decide(folder, c), c)
        }
        assertAsk(decide(folder, "grep x f", ctx(folder: "/proj/../\u{301}etc")))
        assertAsk(decide([rule("f", scope: .projectFolder("/proj/../\u{301}etc"))], "grep x f", ctx(folder: "/etc")))
        assertAllow(decide(folder, "grep x f", ctx(folder: "/proj/\u{301}x")), "f")
    }

    func testRulesBuiltFromAnUnverifiedStoreAskForEverything() {
        let b = RuleBook(rules: [rule("r", scope: .project)], onboardedProjects: ["p1"], hasUnverifiedRules: true)
        XCTAssertEqual(b.decide(command: "grep x f", context: ctx(), now: now),
                       .ask(reason: RuleBook.unverifiedReason))
        XCTAssertEqual(RuleBook.unverifiedReason, "A standing rule could not be verified, so everything asks until it is fixed")
    }

    func testStrictCodableRejectsUnknownKeysAndWrongTypes() throws {
        let good = try JSONEncoder().encode(rule("r", scope: .project))
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        func decodes(_ d: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: d) else { return false }
            return (try? JSONDecoder().decode(Rule.self, from: data)) != nil
        }
        XCTAssertTrue(decodes(dict))
        var extra = dict; extra["bypass"] = true
        XCTAssertFalse(decodes(extra), "unknown key")
        var wrong = dict; wrong["id"] = 5
        XCTAssertFalse(decodes(wrong), "wrong type id")
        wrong = dict; wrong["enabledForProjects"] = "p1"
        XCTAssertFalse(decodes(wrong), "wrong type set")
        wrong = dict; wrong["expiresAt"] = "tomorrow"
        XCTAssertFalse(decodes(wrong), "wrong type date")
        dict["scope"] = ["kind": "project", "extra": 1]
        XCTAssertFalse(decodes(dict), "unknown scope key")
        dict["scope"] = ["kind": "project", "value": "x"]
        XCTAssertFalse(decodes(dict), "value on a scope that takes none")
        dict["scope"] = ["kind": 5]
        XCTAssertFalse(decodes(dict), "wrong type kind")
    }

    // MARK: second review round: xcodebuild action words

    func testAskRuleForAnXcodebuildActionFiresWhereverTheActionWordSits() {
        let rules = [rule("allowX", .buildAndTest, command: "xcodebuild", scope: .project),
                     rule("askTest", .buildAndTest, command: "xcodebuild", subcommand: "test", scope: .project, effect: .ask)]
        for c in ["xcodebuild test", "xcodebuild -scheme X test", "xcodebuild -scheme X -destination Y test",
                  "xcodebuild -scheme X -destination 'platform=macOS' test -quiet"] {
            assertAsk(decide(rules, c), c)
        }
        assertAllow(decide(rules, "xcodebuild -scheme X build"), "allowX")
    }

    func testAllowRuleWithAnXcodebuildSubcommandMatchesTheUsualFormOnly() {
        let rules = [rule("allowBuild", .buildAndTest, command: "xcodebuild", subcommand: "build", scope: .project)]
        assertAllow(decide(rules, "xcodebuild build"), "allowBuild")
        assertAllow(decide(rules, "xcodebuild -scheme X -destination Y build"), "allowBuild")
        assertAsk(decide(rules, "xcodebuild -scheme X test"))
        assertAsk(decide(rules, "xcodebuild build test"))
        assertAsk(decide(rules, "xcodebuild -scheme build"))
    }
}
