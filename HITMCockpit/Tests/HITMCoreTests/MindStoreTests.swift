import XCTest
import Foundation
@testable import HITMCore

final class MindStoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("hitm-mind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let r = root!
        addTeardownBlock { try? FileManager.default.removeItem(at: r) }
    }

    var hitm: URL { root.appendingPathComponent(".hitm", isDirectory: true) }
    func childURL(_ id: String) -> URL { hitm.appendingPathComponent("entries/\(id).json") }

    @discardableResult
    func add(_ s: MindStore, kind: MindKind = .memory, title: String = "T", body: String = "body",
             tags: [String] = [], role: String? = nil, evidence: [String] = [], sensitive: Bool = false,
             parentID: String? = nil, supersedes: String? = nil) throws -> MindRecord {
        try s.propose(kind: kind, title: title, body: body, tags: tags, role: role, evidence: evidence,
                      author: "tester", sensitive: sensitive, parentID: parentID, supersedes: supersedes)
    }

    func acceptedAdd(_ s: MindStore, kind: MindKind = .memory, title: String = "T", body: String = "body",
                     tags: [String] = [], role: String? = nil, sensitive: Bool = false,
                     parentID: String? = nil) throws -> MindRecord {
        let r = try add(s, kind: kind, title: title, body: body, tags: tags, role: role,
                        sensitive: sensitive, parentID: parentID)
        return try acc(s, r.id)
    }

    @discardableResult
    func acc(_ s: MindStore, _ id: String) throws -> MindRecord {
        let kind = try XCTUnwrap(s.record(id: id)).kind
        let a = try XCTUnwrap(MindPolicy.approve(kind: kind, entryID: id, profile: .light, gate: nil, human: "h"))
        return try s.accept(id: id, approval: a)
    }

    func logEvents() throws -> [Event] {
        let text = try String(contentsOf: hitm.appendingPathComponent("log.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
    }

    // MARK: persistence

    func testCreatesLayout() throws {
        _ = try MindStore(root: root)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: hitm.appendingPathComponent("entries").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hitm.appendingPathComponent("mind.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hitm.appendingPathComponent("log.jsonl").path))
    }

    func testStateSurvivesReopenAndRevisionsContinue() throws {
        let s = try MindStore(root: root)
        let a = try add(s, title: "first")
        _ = try acc(s, a.id)
        let before = try logEvents().map(\.revision)
        XCTAssertEqual(before, [1, 2])

        let s2 = try MindStore(root: root)
        XCTAssertEqual(s2.records.count, 1)
        XCTAssertEqual(s2.record(id: a.id)?.status, .accepted)
        let b = try add(s2, title: "second")
        XCTAssertGreaterThan(b.createdRevision, a.createdRevision)
        let after = try logEvents().map(\.revision)
        XCTAssertEqual(after, [1, 2, 3])
        XCTAssertEqual(after, after.sorted())
        XCTAssertEqual(Set(after).count, after.count)
    }

    func testCorruptIndexFailsToOpen() throws {
        _ = try MindStore(root: root)
        try Data("not json".utf8).write(to: hitm.appendingPathComponent("mind.json"))
        XCTAssertThrowsError(try MindStore(root: root)) { XCTAssertEqual($0 as? MindError, .integrityFailure) }
    }

    func testIndexWithPathTraversalIdFailsToOpen() throws {
        let s = try MindStore(root: root)
        let r = try add(s)
        let url = hitm.appendingPathComponent("mind.json")
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: r.id, with: "../../evil")
        try Data(text.utf8).write(to: url)
        XCTAssertThrowsError(try MindStore(root: root)) { XCTAssertEqual($0 as? MindError, .integrityFailure) }
    }

    // MARK: propose

    func testProposeAlwaysQuarantinedAndLogged() throws {
        let s = try MindStore(root: root)
        let r = try add(s, kind: .policy, title: "p", body: "b", tags: ["x"], role: "planner", evidence: ["e"])
        XCTAssertEqual(r.status, .quarantined)
        XCTAssertEqual(r.kind, .policy)
        XCTAssertEqual(r.role, "planner")
        XCTAssertEqual(r.sha256.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: childURL(r.id).path))
        let ev = try logEvents()
        XCTAssertEqual(ev.last?.kind, "propose")
        XCTAssertEqual(ev.last?.author, "tester")
        XCTAssertEqual(ev.last?.revision, r.createdRevision)
    }

    func testInvalidProposeLeavesNothingBehind() throws {
        let s = try MindStore(root: root)
        let entries = hitm.appendingPathComponent("entries")
        let indexBefore = try Data(contentsOf: hitm.appendingPathComponent("mind.json"))
        let logBefore = try Data(contentsOf: hitm.appendingPathComponent("log.jsonl"))
        XCTAssertThrowsError(try add(s, title: "  \n ")) { XCTAssertEqual($0 as? MindError, .invalidEntry) }
        XCTAssertThrowsError(try add(s, body: "\u{01}\u{02}")) { XCTAssertEqual($0 as? MindError, .invalidEntry) }
        XCTAssertThrowsError(try add(s, parentID: "missing")) { XCTAssertEqual($0 as? MindError, .invalidEntry) }
        XCTAssertThrowsError(try add(s, supersedes: "missing")) { XCTAssertEqual($0 as? MindError, .invalidEntry) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: entries.path), [])
        XCTAssertEqual(try Data(contentsOf: hitm.appendingPathComponent("mind.json")), indexBefore)
        XCTAssertEqual(try Data(contentsOf: hitm.appendingPathComponent("log.jsonl")), logBefore)
        XCTAssertEqual(s.records.count, 0)
    }

    func testBodyControlCharactersSanitized() throws {
        let s = try MindStore(root: root)
        let r = try add(s, title: "ti\u{07}tle\nx", body: "a\u{00}b\tc\nd\u{1B}[31m\u{200B}e\r")
        let slices = try { () throws -> [MindSlice] in
            _ = try acc(s, r.id)
            return try s.slices(role: "any", kinds: [.memory], tags: [], budgetCharacters: 1000, destination: .local)
        }()
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices[0].body, "ab\tc\nd[31me")
        XCTAssertEqual(slices[0].title, "title x")
    }

    func testCapsApplied() throws {
        let s = try MindStore(root: root)
        let tags = (0..<15).map { "tag\($0)" } + [String(repeating: "t", count: 100)]
        let r = try add(s, title: String(repeating: "x", count: 500), body: String(repeating: "y", count: 25_000),
                        tags: tags, evidence: (0..<15).map { _ in String(repeating: "e", count: 400) })
        XCTAssertEqual(r.tags.count, 10)
        _ = try acc(s, r.id)
        let sl = try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: 100_000, destination: .local)
        XCTAssertEqual(sl[0].title.unicodeScalars.count, 120)
        XCTAssertEqual(sl[0].body.unicodeScalars.count, 20_000)
        let data = try Data(contentsOf: childURL(r.id))
        let e = try JSONDecoder().decode(MindEntry.self, from: data)
        XCTAssertEqual(e.evidence.count, 10)
        XCTAssertTrue(e.evidence.allSatisfy { $0.unicodeScalars.count == 300 })

        let long = try add(s, tags: [String(repeating: "t", count: 100)])
        XCTAssertEqual(long.tags[0].unicodeScalars.count, 40)
    }

    // MARK: transitions

    func testLegalAndIllegalTransitions() throws {
        let s = try MindStore(root: root)
        let a = try add(s)
        XCTAssertThrowsError(try s.expire(id: a.id, by: "h")) { XCTAssertEqual($0 as? MindError, .illegalTransition) }
        XCTAssertEqual(try acc(s, a.id).status, .accepted)
        XCTAssertThrowsError(try acc(s, a.id)) { XCTAssertEqual($0 as? MindError, .illegalTransition) }
        XCTAssertThrowsError(try s.reject(id: a.id, by: "h", reason: "r")) { XCTAssertEqual($0 as? MindError, .illegalTransition) }
        XCTAssertEqual(try s.expire(id: a.id, by: "h").status, .expired)
        XCTAssertThrowsError(try acc(s, a.id)) { XCTAssertEqual($0 as? MindError, .illegalTransition) }
        XCTAssertThrowsError(try s.correct(id: a.id, reason: "r", by: "h")) { XCTAssertEqual($0 as? MindError, .illegalTransition) }

        let b = try add(s)
        XCTAssertEqual(try s.reject(id: b.id, by: "h", reason: "no").status, .rejected)
        XCTAssertThrowsError(try acc(s, b.id)) { XCTAssertEqual($0 as? MindError, .illegalTransition) }
        XCTAssertThrowsError(try s.expire(id: b.id, by: "h")) { XCTAssertEqual($0 as? MindError, .illegalTransition) }
        XCTAssertThrowsError(try s.accept(id: "nope", approval: MindPolicy.approve(kind: .memory, entryID: "nope", profile: .light, gate: nil, human: "h")!)) { XCTAssertEqual($0 as? MindError, .unknownEntry) }
        XCTAssertThrowsError(try s.reject(id: "nope", by: "h", reason: "")) { XCTAssertEqual($0 as? MindError, .unknownEntry) }
        XCTAssertThrowsError(try s.expire(id: "nope", by: "h")) { XCTAssertEqual($0 as? MindError, .unknownEntry) }
        XCTAssertThrowsError(try s.correct(id: "nope", reason: "", by: "h")) { XCTAssertEqual($0 as? MindError, .unknownEntry) }
        XCTAssertThrowsError(try s.children(of: "nope")) { XCTAssertEqual($0 as? MindError, .unknownEntry) }
    }

    func testTransitionsAreLogged() throws {
        let s = try MindStore(root: root)
        let a = try add(s); let b = try add(s); let c = try add(s)
        _ = try acc(s, a.id)
        _ = try s.reject(id: b.id, by: "h", reason: "bad")
        _ = try s.expire(id: a.id, by: "h")
        _ = try s.correct(id: c.id, reason: "oops", by: "h")
        XCTAssertEqual(try logEvents().map(\.kind), ["propose", "propose", "propose", "accept", "reject", "expire", "correction"])
    }

    func testSupersedeFlow() throws {
        let s = try MindStore(root: root)
        let old = try acceptedAdd(s, title: "old")
        let new = try add(s, title: "new", supersedes: old.id)
        XCTAssertEqual(s.record(id: old.id)?.status, .accepted, "supersede only happens on accept")
        _ = try acc(s, new.id)
        XCTAssertEqual(s.record(id: old.id)?.status, .superseded)
        XCTAssertEqual(s.record(id: new.id)?.status, .accepted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: childURL(old.id).path))
        let sl = try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: 1000, destination: .local)
        XCTAssertEqual(sl.map(\.title), ["new"])
        let reopened = try MindStore(root: root)
        XCTAssertEqual(reopened.record(id: old.id)?.status, .superseded)
    }

    func testCorrectionKeepsChildBytes() throws {
        let s = try MindStore(root: root)
        let a = try acceptedAdd(s)
        let q = try add(s)
        let bytesA = try Data(contentsOf: childURL(a.id))
        let bytesQ = try Data(contentsOf: childURL(q.id))
        XCTAssertEqual(try s.correct(id: a.id, reason: "wrong", by: "h").status, .corrected)
        XCTAssertEqual(try s.correct(id: q.id, reason: "wrong", by: "h").status, .corrected)
        XCTAssertEqual(try Data(contentsOf: childURL(a.id)), bytesA)
        XCTAssertEqual(try Data(contentsOf: childURL(q.id)), bytesQ)
        XCTAssertEqual(try s.audit(), [])
    }

    // MARK: audit

    func testCleanAuditEmpty() throws {
        let s = try MindStore(root: root)
        _ = try acceptedAdd(s)
        XCTAssertEqual(try s.audit(), [])
    }

    func testTamperedChildUntrustedAndExcluded() throws {
        let s = try MindStore(root: root)
        let a = try acceptedAdd(s, title: "keep")
        let b = try acceptedAdd(s, title: "tamper")
        let h = try FileHandle(forWritingTo: childURL(b.id))
        try h.seekToEnd(); try h.write(contentsOf: Data([0x20])); try h.close()
        XCTAssertEqual(try s.audit(), [.untrusted(b.id)])
        let sl = try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: 1000, destination: .local)
        XCTAssertEqual(sl.map(\.id), [a.id])
    }

    func testDeletedChildUntrusted() throws {
        let s = try MindStore(root: root)
        let b = try acceptedAdd(s)
        try FileManager.default.removeItem(at: childURL(b.id))
        XCTAssertEqual(try s.audit(), [.untrusted(b.id)])
        XCTAssertTrue(try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: 1000, destination: .local).isEmpty)
    }

    func testOrphanFileReported() throws {
        let s = try MindStore(root: root)
        try Data("{}".utf8).write(to: hitm.appendingPathComponent("entries/stray.json"))
        XCTAssertEqual(try s.audit(), [.orphan("stray.json")])
        _ = try acceptedAdd(s)
        XCTAssertEqual(try s.audit(), [.orphan("stray.json")])
    }

    // MARK: slices

    func testHostedModelExcludesSensitiveAndDescendants() throws {
        let s = try MindStore(root: root)
        let top = try acceptedAdd(s, kind: .context, title: "top", sensitive: false)
        let mid = try acceptedAdd(s, kind: .context, title: "mid", sensitive: true, parentID: top.id)
        let leaf = try acceptedAdd(s, kind: .context, title: "leaf", sensitive: false, parentID: mid.id)
        let hosted = try s.slices(role: "r", kinds: [.context], tags: [], budgetCharacters: 10_000, destination: .hostedModel)
        XCTAssertEqual(hosted.map(\.id), [top.id])
        let local = try s.slices(role: "r", kinds: [.context], tags: [], budgetCharacters: 10_000, destination: .local)
        XCTAssertEqual(Set(local.map(\.id)), [top.id, mid.id, leaf.id])
        XCTAssertEqual(local.map(\.id), [leaf.id, mid.id, top.id], "newest revision first")
    }

    func testSliceFiltersRoleKindTags() throws {
        let s = try MindStore(root: root)
        let all = try acceptedAdd(s, title: "all", tags: ["a"])
        let planner = try acceptedAdd(s, title: "planner", tags: ["b"], role: "planner")
        _ = try acceptedAdd(s, title: "coder", tags: ["a"], role: "coder")
        _ = try acceptedAdd(s, kind: .prompt, title: "prompt", tags: ["a"])
        func ids(role: String, kinds: Set<MindKind>, tags: [String]) throws -> [String] {
            try s.slices(role: role, kinds: kinds, tags: tags, budgetCharacters: 10_000, destination: .local).map(\.id)
        }
        XCTAssertEqual(Set(try ids(role: "planner", kinds: [.memory], tags: [])), [all.id, planner.id])
        XCTAssertEqual(try ids(role: "planner", kinds: [.memory], tags: ["a"]), [all.id])
        XCTAssertEqual(try ids(role: "planner", kinds: [.memory], tags: ["zzz"]), [])
        XCTAssertEqual(try ids(role: "planner", kinds: [.policy], tags: []), [])
        XCTAssertEqual(try ids(role: "planner", kinds: [], tags: []), [])
        XCTAssertEqual(try ids(role: "other", kinds: [.memory], tags: ["b"]), [])
    }

    func testBudgetWholeEntriesThenTruncateNeverExceed() throws {
        let s = try MindStore(root: root)
        _ = try acceptedAdd(s, title: "A", body: String(repeating: "a", count: 50))
        let newer = try acceptedAdd(s, title: "B", body: String(repeating: "b", count: 30))
        func total(_ sl: [MindSlice]) -> Int { sl.reduce(0) { $0 + $1.title.unicodeScalars.count + $1.body.unicodeScalars.count } }
        let big = try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: 1000, destination: .local)
        XCTAssertEqual(big.count, 2)
        XCTAssertEqual(big[0].id, newer.id)

        let mid = try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: 50, destination: .local)
        XCTAssertEqual(mid.count, 2)
        XCTAssertEqual(mid[0].body.count, 30)
        XCTAssertTrue(mid[1].body.hasSuffix("…"))
        XCTAssertLessThanOrEqual(total(mid), 50)

        let tiny = try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: 10, destination: .local)
        XCTAssertEqual(tiny.count, 1)
        XCTAssertTrue(tiny[0].body.hasSuffix("…"))
        XCTAssertLessThanOrEqual(total(tiny), 10)

        for b in 0...100 {
            XCTAssertLessThanOrEqual(total(try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: b, destination: .local)), b)
        }
        XCTAssertTrue(try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: 0, destination: .local).isEmpty)
    }

    func testNonAcceptedNeverSliced() throws {
        let s = try MindStore(root: root)
        let quarantined = try add(s, title: "q")
        let rejected = try add(s, title: "r"); _ = try s.reject(id: rejected.id, by: "h", reason: "x")
        let expired = try acceptedAdd(s, title: "e"); _ = try s.expire(id: expired.id, by: "h")
        let corrected = try acceptedAdd(s, title: "c"); _ = try s.correct(id: corrected.id, reason: "x", by: "h")
        let old = try acceptedAdd(s, title: "old")
        let new = try add(s, title: "new", supersedes: old.id); _ = try acc(s, new.id)
        let sl = try s.slices(role: "r", kinds: Set(MindKind.allCases), tags: [], budgetCharacters: 10_000, destination: .local)
        XCTAssertEqual(sl.map(\.title), ["new"])
        XCTAssertNotNil(s.record(id: quarantined.id))
    }

    func testNestingAndChildren() throws {
        let s = try MindStore(root: root)
        let ctx = try add(s, kind: .context, title: "ctx")
        let s1 = try add(s, kind: .context, title: "s1", parentID: ctx.id)
        let s2 = try add(s, kind: .context, title: "s2", parentID: ctx.id)
        let other = try add(s, kind: .context, title: "other")
        XCTAssertEqual(try s.children(of: ctx.id).map(\.id), [s1.id, s2.id])
        XCTAssertEqual(try s.children(of: other.id), [])
        XCTAssertEqual(s1.parentID, ctx.id)
    }

    // MARK: policy

    func testMindPolicyTable() {
        let unsure = RiskProfile(name: "u", extraHumanRequired: [], unsure: true)
        let sensitive = RiskProfile(name: "s", extraHumanRequired: [], sensitive: true)
        let profiles: [(String, RiskProfile)] = [("light", .light), ("strict", .strict), ("unsure", unsure), ("sensitive", sensitive)]
        let quiet = GateResponse(route: .proceed, needsHuman: false, detailLevel: 0, confidence: 0.9, reason: "ok")
        let humanFlag = GateResponse(route: .proceed, needsHuman: true, detailLevel: 1, confidence: 0.9, reason: "ok")
        let askRoute = GateResponse(route: .askHuman, needsHuman: false, detailLevel: 1, confidence: 0.9, reason: "ok")
        let gates: [(String, Result<GateResponse, GateError>?, Bool)] = [
            ("nil", nil, true), ("failure", .failure(.unavailable), true), ("quiet", .success(quiet), false),
            ("needsHuman", .success(humanFlag), true), ("askRoute", .success(askRoute), true)
        ]
        for kind in MindKind.allCases {
            for (pn, p) in profiles {
                for (gn, g, gateBad) in gates {
                    let got = MindPolicy.needsHuman(kind: kind, profile: p, gate: g)
                    let label = "\(kind) \(pn) \(gn)"
                    let heavy = pn != "light" // strict, unsure, sensitive
                    switch kind {
                    case .policy: XCTAssertTrue(got, label)
                    case .prompt: XCTAssertEqual(got, heavy || gateBad, label)
                    case .context, .memory: XCTAssertEqual(got, pn == "unsure" || pn == "sensitive" || gateBad, label)
                    }
                }
            }
        }
        // the explicit invariants
        XCTAssertFalse(MindPolicy.needsHuman(kind: .memory, profile: .light, gate: .success(quiet)))
        XCTAssertFalse(MindPolicy.needsHuman(kind: .memory, profile: .strict, gate: .success(quiet)))
        XCTAssertFalse(MindPolicy.needsHuman(kind: .context, profile: .light, gate: .success(quiet)))
        XCTAssertFalse(MindPolicy.needsHuman(kind: .prompt, profile: .light, gate: .success(quiet)))
    }
}
