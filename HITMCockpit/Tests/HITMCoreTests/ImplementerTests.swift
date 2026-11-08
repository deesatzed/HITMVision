import XCTest
@testable import HITMCore

final class ImplementerTests: XCTestCase {
    private func json(_ summary: String, _ edits: [(String, String)]) -> Data {
        let e = edits.map { ["path": $0.0, "content": $0.1] }
        return try! JSONSerialization.data(withJSONObject: ["summary": summary, "edits": e])
    }

    func testAcceptsAWellFormedChangeSet() throws {
        let cs = try ChangeSet.decodeStrict(json("Adds a docstring.", [("a.py", "x = 1\n"), ("sub/b.py", "y")])).get()
        XCTAssertEqual(cs.edits.map(\.path), ["a.py", "sub/b.py"])
        XCTAssertEqual(cs.summary, "Adds a docstring.")
    }

    func testUnsafePathsAreRejected() {
        for p in ["/etc/passwd", "../x", "a/../../x", ".git/config", "sub/.git/hooks/pre-commit", ".GIT/config", ".hitm/ledger.jsonl",
                  ".env", ".env.local", "a\\b", "a//b", "a/./b", "", "dir/", ".gitattributes", "name.", "a\u{202E}b.py", "\u{FF0E}git/config"] {
            if p == "\u{FF0E}git/config" { // fullwidth dot normalizes to ".git" under NFKC
                XCTAssertEqual(ChangeSet.decodeStrict(json("s", [(p, "x")])), .failure(.unsafePath), p); continue
            }
            XCTAssertEqual(ChangeSet.decodeStrict(json("s", [(p, "x")])), .failure(.unsafePath), p)
        }
    }

    func testBoundsAndDuplicates() {
        XCTAssertEqual(ChangeSet.decodeStrict(json("s", [])), .failure(.outOfRange))
        XCTAssertEqual(ChangeSet.decodeStrict(json("s", (0..<7).map { ("f\($0).py", "x") })), .failure(.outOfRange))
        XCTAssertEqual(ChangeSet.decodeStrict(json("s", [("A.py", "x"), ("a.PY", "y")])), .failure(.outOfRange))
        XCTAssertEqual(ChangeSet.decodeStrict(json("s", [("a.py", String(repeating: "x", count: 30_001))])), .failure(.outOfRange))
        XCTAssertEqual(ChangeSet.decodeStrict(json("s", [("a.py", "x\0y")])), .failure(.outOfRange))
        XCTAssertEqual(ChangeSet.decodeStrict(json("   ", [("a.py", "x")])), .failure(.outOfRange))
    }

    func testMalformedJSONAndExtraKeysBehavior() {
        XCTAssertEqual(ChangeSet.decodeStrict(Data("nope".utf8)), .failure(.malformed))
        XCTAssertEqual(ChangeSet.decodeStrict(Data(#"{"summary":"s"}"#.utf8)), .failure(.malformed))
        XCTAssertEqual(ChangeSet.decodeStrict(Data(#"{"summary":"s","edits":[{"path":"a","content":1}]}"#.utf8)), .failure(.malformed))
    }

    func testPromptMarksRepoFilesAsDataAndIsStable() {
        let p = Proposal(title: "T", steps: [ProposalStep(text: "do it", claimedClass: .routine)], risks: [], questions: [])
        let a = ImplementerAgent.messages(intent: "intent", proposal: p, files: ["b.py": "B", "a.py": "A"])
        let b = ImplementerAgent.messages(intent: "intent", proposal: p, files: ["a.py": "A", "b.py": "B"])
        XCTAssertEqual(a, b)
        XCTAssertTrue(a[0].content.contains("DATA"))
        XCTAssertTrue(a[1].content.contains("=== a.py ==="))
    }

    func testSensitiveProfileMakesNoCall() async {
        // The transport points at an unroutable key/endpoint; a call would not return .blockedBySensitiveProfile.
        let agent = ImplementerAgent(transport: OpenRouterTransport(apiKey: "k", model: "m"))
        let p = Proposal(title: "T", steps: [ProposalStep(text: "x", claimedClass: .routine)], risks: [], questions: [])
        for prof in [RiskProfile(name: "s", extraHumanRequired: [], sensitive: true),
                     RiskProfile(name: "u", extraHumanRequired: [], unsure: true)] {
            let (r, rec) = await agent.implement(intent: "i", proposal: p, files: [:], profile: prof)
            XCTAssertEqual(r, .failure(.blockedBySensitiveProfile)); XCTAssertNil(rec)
        }
    }

    func testOversizeInputMakesNoCall() async {
        let agent = ImplementerAgent(transport: OpenRouterTransport(apiKey: "k", model: "m"))
        let p = Proposal(title: "T", steps: [ProposalStep(text: "x", claimedClass: .routine)], risks: [], questions: [])
        let big = ["a.py": String(repeating: "x", count: ImplementerAgent.maxInputScalars)]
        let (r, rec) = await agent.implement(intent: "i", proposal: p, files: big, profile: .light)
        XCTAssertEqual(r, .failure(.inputTooLarge)); XCTAssertNil(rec)
    }
}

final class CardInboxTests: XCTestCase {
    private func inbox() -> CardInbox {
        CardInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)"))
    }
    private func card(_ id: String, status: CardStatus = .pending) -> ReviewCard {
        ReviewCard(id: id, intent: "i", title: "t", steps: [], overallClass: .routine, branch: "hitm/\(id)", changedPaths: ["a.py"],
                   diff: "+x", diffTruncated: false, addedLines: 1, removedLines: 0, needsHuman: true, detailLevel: 1,
                   reasons: ["r"], gateFailed: false, models: [:], status: status)
    }

    func testWriteLoadAndList() throws {
        let box = inbox()
        try box.write(card("c1")); try box.write(card("c2"))
        XCTAssertEqual(try box.load("c1").title, "t")
        XCTAssertEqual(box.list().count, 2)
    }

    func testIDsThatCouldEscapeTheFolderAreRefused() {
        let box = inbox()
        for id in ["../x", "a/b", "", "a.b", String(repeating: "a", count: 65), "é"] {
            XCTAssertThrowsError(try box.load(id), id) { XCTAssertEqual($0 as? InboxError, .invalidID) }
        }
    }

    func testDecisionNeedsANamedHumanAndHappensOnce() throws {
        let box = inbox(); try box.write(card("c1"))
        XCTAssertThrowsError(try box.decide("c1", to: .passed, by: "  ")) { XCTAssertEqual($0 as? InboxError, .humanNameRequired) }
        XCTAssertThrowsError(try box.decide("c1", to: .quietPassed, by: "me")) { XCTAssertEqual($0 as? InboxError, .notAHumanDecision) }
        XCTAssertEqual(try box.load("c1").status, .pending)
        let d = try box.decide("c1", to: .passed, by: " reviewer ")
        XCTAssertEqual(d.status, .passed); XCTAssertEqual(d.decidedBy, "reviewer")
        XCTAssertThrowsError(try box.decide("c1", to: .rejected, by: "me")) { XCTAssertEqual($0 as? InboxError, .alreadyDecided) }
        XCTAssertEqual(try box.load("c1").status, .passed)
    }

    func testDecisionIsAppendedToEvents() throws {
        let box = inbox(); try box.write(card("c1"))
        try box.decide("c1", to: .rejected, by: "me")
        let text = String(decoding: try Data(contentsOf: box.directory.appendingPathComponent("events.jsonl")), as: UTF8.self)
        XCTAssertTrue(text.contains("\"kind\":\"rejected\"") && text.contains("\"cardID\":\"c1\""))
    }

    func testAQuietCardCannotBeDecidedByAHuman() throws {
        let box = inbox(); try box.write(card("q", status: .quietPassed))
        XCTAssertThrowsError(try box.decide("q", to: .passed, by: "me")) { XCTAssertEqual($0 as? InboxError, .alreadyDecided) }
    }
}
