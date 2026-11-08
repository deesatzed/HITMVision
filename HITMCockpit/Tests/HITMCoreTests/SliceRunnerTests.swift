import XCTest
@testable import HITMCore

#if os(macOS)
/// Real git, real worktrees, real files. The three model roles are TEST DOUBLES (closures) so no network is used; the
/// real models are exercised only by the manual `LiveSlice run` command.
final class SliceRunnerTests: XCTestCase {
    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func g(_ a: [String]) throws { try Workspace.git(["-c", "user.name=t", "-c", "user.email=t@t"] + a, in: dir) }
        try g(["init", "-q", "-b", "main"])
        try "def add(a, b):\n    return a + b\n".write(to: dir.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        try "# demo\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try g(["add", "-A"]); try g(["commit", "-q", "-m", "init"])
        return dir
    }

    private static func ok(_ cost: Double? = 0.001) -> CallRecord {
        CallRecord(requestedModel: "m", usedModel: "m", httpStatus: 200, latencyMs: 1, promptTokens: 1, completionTokens: 1, costUSD: cost, outcome: "ok")
    }

    private func deps(stepText: String = "Add a docstring to add()", claimed: ActionClass = .routine,
                      newCalc: String = "def add(a, b):\n    \"\"\"Add two numbers.\"\"\"\n    return a + b\n",
                      summary: String = "Adds a docstring.", gateNeedsHuman: Bool = false, gateFails: Bool = false,
                      counter: Counter = Counter()) -> SliceDeps {
        SliceDeps(
            plan: { _, _ in
                counter.bump("plan")
                return (.success(Proposal(title: "Document add", steps: [ProposalStep(text: stepText, claimedClass: claimed)], risks: [], questions: [])), SliceRunnerTests.ok())
            },
            implement: { _, _, _, _ in
                counter.bump("implement")
                return (.success(ChangeSet(summary: summary, edits: [FileEdit(path: "calc.py", content: newCalc)])), SliceRunnerTests.ok())
            },
            gate: { _ in
                counter.bump("gate")
                if gateFails { return (.failure(.unavailable), SliceRunnerTests.ok(nil)) }
                return (.success(GateResponse(route: gateNeedsHuman ? .askHuman : .proceed, needsHuman: gateNeedsHuman, detailLevel: 1, confidence: 0.9, reason: "stand-in gate")), SliceRunnerTests.ok())
            },
            models: ["planner": "stand-in", "implementer": "stand-in", "gate": "stand-in"])
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n: [String: Int] = [:]
        func bump(_ k: String) { lock.lock(); n[k, default: 0] += 1; lock.unlock() }
        func count(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; return n[k, default: 0] }
    }

    private func branches(_ repo: URL) throws -> [String] {
        try Workspace.git(["branch", "--format=%(refname:short)"], in: repo).split(separator: "\n").map(String.init)
    }

    func testQuietPathCommitsOnItsBranchOnlyAndLeavesMainUntouched() async throws {
        let repo = try makeRepo()
        let before = try Workspace.git(["rev-parse", "main"], in: repo)
        let c = Counter()
        let card = await SliceRunner(workspace: try Workspace(repo: repo), deps: deps(counter: c)).run(intent: "document add")
        XCTAssertEqual(card.status, .quietPassed); XCTAssertFalse(card.needsHuman)
        XCTAssertEqual(card.changedPaths, ["calc.py"]); XCTAssertTrue(card.diff.contains("+    \"\"\"Add two numbers.\"\"\""))
        XCTAssertEqual(card.addedLines, 1); XCTAssertEqual(card.removedLines, 0)
        XCTAssertEqual(try Workspace.git(["rev-parse", "main"], in: repo), before)
        XCTAssertEqual(try Workspace.git(["status", "--porcelain"], in: repo), "")
        let branch = try XCTUnwrap(card.branch)
        XCTAssertTrue(try branches(repo).contains(branch))
        XCTAssertEqual(try Workspace.git(["log", "-1", "--format=%s", branch], in: repo).trimmingCharacters(in: .whitespacesAndNewlines), "Document add")
        XCTAssertEqual([c.count("plan"), c.count("implement"), c.count("gate")], [1, 1, 1])
        XCTAssertEqual(try CardInbox(directory: repo.appendingPathComponent(".hitm/inbox")).load(card.id).status, .quietPassed)
    }

    func testGateAskingMakesAPendingCardWithNoCommitThenPassCommitsOnBranch() async throws {
        let repo = try makeRepo()
        let runner = SliceRunner(workspace: try Workspace(repo: repo), deps: deps(gateNeedsHuman: true))
        let card = await runner.run(intent: "document add")
        XCTAssertEqual(card.status, .pending); XCTAssertTrue(card.needsHuman)
        let branch = try XCTUnwrap(card.branch)
        XCTAssertEqual(try Workspace.git(["rev-list", "--count", branch], in: repo).trimmingCharacters(in: .whitespacesAndNewlines), "1")   // still only init
        let decided = try runner.resolve(cardID: card.id, pass: true, by: "reviewer")
        XCTAssertEqual(decided.status, .passed)
        XCTAssertEqual(try Workspace.git(["rev-list", "--count", branch], in: repo).trimmingCharacters(in: .whitespacesAndNewlines), "2")
        XCTAssertEqual(try Workspace.git(["rev-parse", "main"], in: repo).count, 41)
    }

    func testRejectRemovesWorktreeAndBranch() async throws {
        let repo = try makeRepo()
        let runner = SliceRunner(workspace: try Workspace(repo: repo), deps: deps(gateNeedsHuman: true))
        let card = await runner.run(intent: "x")
        let branch = try XCTUnwrap(card.branch)
        _ = try runner.resolve(cardID: card.id, pass: false, by: "reviewer")
        XCTAssertFalse(try branches(repo).contains(branch))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".hitm/worktrees/\(card.id)").path))
        XCTAssertEqual(try CardInbox(directory: repo.appendingPathComponent(".hitm/inbox")).load(card.id).status, .rejected)
    }

    func testGateFailureAsksTheHuman() async throws {
        let card = await SliceRunner(workspace: try Workspace(repo: try makeRepo()), deps: deps(gateFails: true)).run(intent: "x")
        XCTAssertEqual(card.status, .pending); XCTAssertTrue(card.gateFailed)
    }

    func testFloorWinsOverAGateThatSaysProceed() async throws {
        // The plan claims routine, but the step text is deletion: the classifier raises it, the gate says proceed, the human still asks.
        let card = await SliceRunner(workspace: try Workspace(repo: try makeRepo()),
                                     deps: deps(stepText: "Delete the old test files", claimed: .routine)).run(intent: "x")
        XCTAssertEqual(card.status, .pending); XCTAssertEqual(card.overallClass, .irreversible)
    }

    func testAnAddedDangerousLineRaisesTheFloorEvenWhenThePlanLooksRoutine() async throws {
        let card = await SliceRunner(workspace: try Workspace(repo: try makeRepo()),
            deps: deps(newCalc: "import os\nos.system('rm -rf build')\n")).run(intent: "x")
        XCTAssertEqual(card.status, .pending); XCTAssertEqual(card.overallClass, .irreversible)
        XCTAssertTrue(card.reasons.first?.contains("An added line") ?? false)
    }

    func testStrictProfileAsksForDomainLogic() async throws {
        let card = await SliceRunner(workspace: try Workspace(repo: try makeRepo()),
                                     deps: deps(stepText: "Change the pricing calculation", claimed: .editDomainLogic), profile: .strict).run(intent: "x")
        XCTAssertEqual(card.status, .pending)
    }

    func testSensitiveProfileSendsNothingAndProducesAFailedCard() async throws {
        let c = Counter()
        let d = SliceDeps(plan: { _, p in c.bump("plan"); return await PlannerAgent(transport: OpenRouterTransport(apiKey: "k", model: "m")).propose(intent: "i", profile: p) },
                          implement: { _, _, _, _ in c.bump("implement"); return (.failure(.unavailable), nil) },
                          gate: { _ in c.bump("gate"); return (.failure(.unavailable), SliceRunnerTests.ok(nil)) }, models: [:])
        let card = await SliceRunner(workspace: try Workspace(repo: try makeRepo()), deps: d,
                                     profile: RiskProfile(name: "s", extraHumanRequired: [], sensitive: true)).run(intent: "x")
        XCTAssertEqual(card.status, .failed); XCTAssertEqual(c.count("implement"), 0); XCTAssertEqual(c.count("gate"), 0)
    }

    func testIdenticalFilesMeansNoChangeAndNoBranchLeftBehind() async throws {
        let repo = try makeRepo()
        let card = await SliceRunner(workspace: try Workspace(repo: repo),
                                     deps: deps(newCalc: "def add(a, b):\n    return a + b\n")).run(intent: "x")
        XCTAssertEqual(card.status, .failed)
        XCTAssertEqual(try branches(repo), ["main"])
    }

    func testCallCapStopsTheRunBeforeTheImplementerIsCalled() async throws {
        let c = Counter()
        let card = await SliceRunner(workspace: try Workspace(repo: try makeRepo()), deps: deps(counter: c),
                                     limits: LedgerLimits(maxCalls: 1, maxKnownCostUSD: 1)).run(intent: "x")
        XCTAssertEqual(card.status, .failed); XCTAssertEqual(c.count("plan"), 1); XCTAssertEqual(c.count("implement"), 0)
        XCTAssertTrue(card.reasons.first?.contains("budget") ?? false)
    }

    func testEveryCallIsInTheLedgerAndNoSecretOrBodyIsStored() async throws {
        let repo = try makeRepo()
        let card = await SliceRunner(workspace: try Workspace(repo: repo), deps: deps()).run(intent: "SECRET-INTENT-TEXT")
        let ledger = CallLedger(fileURL: repo.appendingPathComponent(".hitm/runs/\(card.id).jsonl"))
        XCTAssertEqual(try ledger.entries().map(\.kind), ["intent", "receipt", "intent", "receipt", "intent", "receipt"])
        XCTAssertEqual(try ledger.entries().compactMap(\.role), ["Planner", "Implementer", "Gate"])   // role is on the intent line only
        let text = String(decoding: try Data(contentsOf: ledger.fileURL), as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET-INTENT-TEXT"))
    }

    func testOnlyAPendingCardCanBeResolved() async throws {
        let runner = SliceRunner(workspace: try Workspace(repo: try makeRepo()), deps: deps())
        let card = await runner.run(intent: "x")   // quiet
        XCTAssertThrowsError(try runner.resolve(cardID: card.id, pass: true, by: "me")) { XCTAssertEqual($0 as? InboxError, .alreadyDecided) }
    }

    func testWorkspaceRefusesWritesOutsideTheWorktree() throws {
        let repo = try makeRepo()
        let ws = try Workspace(repo: repo)
        _ = try ws.prepare(id: "cabc")
        // A symlink inside the worktree pointing outside must not be written through.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: ws.worktreeURL("cabc").appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try ws.apply(ChangeSet(summary: "s", edits: [FileEdit(path: "link/pwned.txt", content: "x")]), id: "cabc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("pwned.txt").path))
        XCTAssertThrowsError(try ws.apply(ChangeSet(summary: "s", edits: [FileEdit(path: "link", content: "x")]), id: "cabc"))
    }

    func testNotAGitRepoIsRefused() {
        XCTAssertThrowsError(try Workspace(repo: FileManager.default.temporaryDirectory))
    }
}
#endif

#if os(macOS)
extension SliceRunnerTests {
    func testSyncAppliesDecisionsRecordedWithoutGitAndIsRepeatable() async throws {
        let repo = try makeRepo()
        let runner = SliceRunner(workspace: try Workspace(repo: repo), deps: deps(gateNeedsHuman: true))
        let a = await runner.run(intent: "a"), b = await runner.run(intent: "b")
        // The cockpit app records decisions without touching git.
        try runner.inbox.decide(a.id, to: .passed, by: "me")
        try runner.inbox.decide(b.id, to: .rejected, by: "me")
        let first = runner.sync()
        XCTAssertEqual(first.sorted(), ["committed \(a.id)", "removed \(b.id)"].sorted())
        XCTAssertEqual(try Workspace.git(["rev-list", "--count", try XCTUnwrap(a.branch)], in: repo).trimmingCharacters(in: .whitespacesAndNewlines), "2")
        XCTAssertFalse(try Workspace.git(["branch", "--format=%(refname:short)"], in: repo).contains(try XCTUnwrap(b.branch)))
        XCTAssertEqual(runner.sync(), [])   // second run changes nothing
    }
}
#endif
