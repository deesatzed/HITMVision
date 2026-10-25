import XCTest
import Foundation
import CryptoKit
@testable import HITMCore

extension MindStoreTests {
    var indexURL: URL { hitm.appendingPathComponent("mind.json") }
    var logURL: URL { hitm.appendingPathComponent("log.jsonl") }

    /// Edit index fields and/or child-file fields; nil value removes the key. Recomputes the sha when the child changes.
    func forge(id: String, index: [String: Any?] = [:], entry: [String: Any?] = [:]) throws {
        var top = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        var recs = try XCTUnwrap(top["entries"] as? [[String: Any]])
        let i = try XCTUnwrap(recs.firstIndex { ($0["id"] as? String) == id })
        func apply(_ ch: [String: Any?], _ d: inout [String: Any]) {
            for (k, v) in ch { if let v = v { d[k] = v } else { d.removeValue(forKey: k) } }
        }
        apply(index, &recs[i])
        if !entry.isEmpty {
            var e = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: childURL(id))) as? [String: Any])
            apply(entry, &e)
            let data = try JSONSerialization.data(withJSONObject: e, options: [.sortedKeys])
            try data.write(to: childURL(id))
            recs[i]["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        top["entries"] = recs
        try JSONSerialization.data(withJSONObject: top, options: [.sortedKeys]).write(to: indexURL)
    }

    func hosted(_ s: MindStore) throws -> [MindSlice] {
        try s.slices(role: "r", kinds: Set(MindKind.allCases), tags: [], budgetCharacters: 100_000, destination: .hostedModel)
    }
    func local(_ s: MindStore) throws -> [MindSlice] {
        try s.slices(role: "r", kinds: Set(MindKind.allCases), tags: [], budgetCharacters: 100_000, destination: .local)
    }
    func dropLastLogLine() throws {
        var lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.removeLast()
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: logURL)
    }
    func appendRaw(_ s: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); try h.write(contentsOf: Data(s.utf8)); try h.close()
    }

    // MARK: A. fail closed on structure

    func testGrandchildWithSensitiveRootExcluded() throws {
        let s = try MindStore(root: root)
        let r = try acceptedAdd(s, kind: .context, title: "root", sensitive: true)
        let m = try acceptedAdd(s, kind: .context, title: "mid", sensitive: false, parentID: r.id)
        let g = try acceptedAdd(s, kind: .context, title: "leaf", sensitive: false, parentID: m.id)
        XCTAssertEqual(try hosted(s), [])
        XCTAssertEqual(Set(try local(s).map(\.id)), [r.id, m.id, g.id])
    }

    func testCycleEditedIntoIndexFailsClosed() throws {
        let s = try MindStore(root: root)
        let a = try acceptedAdd(s, kind: .context, title: "a")
        let b = try acceptedAdd(s, kind: .context, title: "b", parentID: a.id)
        try forge(id: a.id, index: ["parentID": b.id], entry: ["parentID": b.id])
        let re = try MindStore(root: root)
        XCTAssertEqual(try hosted(re), [])
    }

    func testMissingParentOrSupersedesRecordFailsOpen() throws {
        let s = try MindStore(root: root)
        let a = try add(s)
        let ghost = "00000000-0000-0000-0000-000000000000"
        try forge(id: a.id, index: ["parentID": ghost], entry: ["parentID": ghost])
        XCTAssertThrowsError(try MindStore(root: root)) { XCTAssertEqual($0 as? MindError, .integrityFailure) }
        try forge(id: a.id, index: ["parentID": nil, "supersedes": ghost], entry: ["parentID": nil, "supersedes": ghost])
        XCTAssertThrowsError(try MindStore(root: root)) { XCTAssertEqual($0 as? MindError, .integrityFailure) }
    }

    func testIdsDifferingOnlyByCaseFailOpen() throws {
        let s = try MindStore(root: root)
        let a = try add(s)
        var top = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        var recs = try XCTUnwrap(top["entries"] as? [[String: Any]])
        var dup = recs[0]; dup["id"] = a.id.lowercased()
        recs.append(dup); top["entries"] = recs
        try JSONSerialization.data(withJSONObject: top).write(to: indexURL)
        XCTAssertThrowsError(try MindStore(root: root)) { XCTAssertEqual($0 as? MindError, .integrityFailure) }
    }

    func testIndexOnlySensitiveFlipIsUntrustedAndTaintsDescendants() throws {
        let s = try MindStore(root: root)
        let p = try acceptedAdd(s, kind: .context, title: "p", sensitive: true)
        let c = try acceptedAdd(s, kind: .context, title: "c", parentID: p.id)
        XCTAssertEqual(try hosted(s), [])
        try forge(id: p.id, index: ["sensitive": false])
        let re = try MindStore(root: root)
        XCTAssertTrue(try re.audit().contains(.untrusted(p.id)))
        XCTAssertEqual(try hosted(re), [], "flipped parent and its child must both be excluded")
        XCTAssertFalse(try local(re).map(\.id).contains(p.id))
        _ = c
    }

    func testIndexRoleTagsKindMismatchUntrusted() throws {
        let s = try MindStore(root: root)
        let a = try acceptedAdd(s, title: "a", tags: ["x"])
        try forge(id: a.id, index: ["role": "coder"])
        XCTAssertEqual(try MindStore(root: root).audit(), [.untrusted(a.id)])
        try forge(id: a.id, index: ["role": nil, "tags": ["y"]])
        XCTAssertEqual(try MindStore(root: root).audit(), [.untrusted(a.id)])
    }

    func testSupersedingSensitiveInheritsSensitivity() throws {
        let s = try MindStore(root: root)
        let old = try acceptedAdd(s, title: "old", sensitive: true)
        let new = try add(s, title: "new", sensitive: false, supersedes: old.id)
        XCTAssertTrue(new.sensitive)
        try acc(s, new.id)
        XCTAssertEqual(try hosted(s), [])
        XCTAssertEqual(try local(s).map(\.title), ["new"])
    }

    func testForgedSupersedesLinkToSensitiveExcludedFromHosted() throws {
        let s = try MindStore(root: root)
        let old = try acceptedAdd(s, title: "old", sensitive: true)
        let plain = try acceptedAdd(s, title: "plain")
        XCTAssertEqual(try hosted(s).map(\.id), [plain.id])
        try forge(id: plain.id, index: ["supersedes": old.id], entry: ["supersedes": old.id])
        XCTAssertEqual(try hosted(try MindStore(root: root)), [])
    }

    // MARK: B. log integrity

    func testMissingOrEmptyLogWithNonEmptyIndexFailsOpen() throws {
        let s = try MindStore(root: root)
        try add(s)
        try FileManager.default.removeItem(at: logURL)
        XCTAssertThrowsError(try MindStore(root: root)) { XCTAssertEqual($0 as? MindError, .integrityFailure) }
        try Data().write(to: logURL)
        XCTAssertThrowsError(try MindStore(root: root)) { XCTAssertEqual($0 as? MindError, .integrityFailure) }
    }

    func testTornFinalLogLineRecoveredAndRevisionsContinue() throws {
        let s = try MindStore(root: root)
        try add(s); try add(s)
        try appendRaw("{\"sessionID\":\"AB", to: logURL)
        let re = try MindStore(root: root)
        XCTAssertEqual(try logEvents().map(\.revision), [1, 2], "torn tail removed from the file")
        try add(re)
        XCTAssertEqual(try logEvents().map(\.revision), [1, 2, 3])
        _ = try MindStore(root: root)
    }

    func testWhitespaceLinesSkippedAndNonFinalGarbageFails() throws {
        let s = try MindStore(root: root)
        try add(s)
        try appendRaw("   \n\n", to: logURL)
        _ = try MindStore(root: root)
        try appendRaw("garbage\n", to: logURL)
        try add(try MindStore(root: root)) // garbage was final (after whitespace): recovered
        try appendRaw("garbage\n", to: logURL)
        let s3 = try MindStore(root: root) // final again, recovered
        try add(s3)
        var lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map(String.init)
        lines.insert("garbage", at: 0)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: logURL)
        XCTAssertThrowsError(try MindStore(root: root)) { XCTAssertEqual($0 as? MindError, .integrityFailure) }
    }

    func testCrashBetweenIndexAndLogGetsFreshRevisionAndAuditReports() throws {
        let s = try MindStore(root: root)
        let a = try acceptedAdd(s, title: "a")
        let b = try add(s, title: "b")
        try dropLastLogLine()                       // b's propose event lost
        let re = try MindStore(root: root)
        let c = try add(re, title: "c")
        XCTAssertGreaterThan(c.createdRevision, max(a.createdRevision, b.createdRevision))
        XCTAssertTrue(try re.audit().contains(.noLogEvent(b.id)))
        XCTAssertEqual(try logEvents().map(\.revision), Array(Set(try logEvents().map(\.revision))).sorted())
    }

    func testLostAcceptEventShowsStatusMismatchAndExcludes() throws {
        let s = try MindStore(root: root)
        let a = try add(s, title: "a")
        try acc(s, a.id)
        try dropLastLogLine()
        let re = try MindStore(root: root)
        XCTAssertEqual(try re.audit(), [.statusMismatch(a.id)])
        XCTAssertEqual(try local(re), [])
    }

    func testIndexOnlyStatusFlipDetected() throws {
        let s = try MindStore(root: root)
        let a = try add(s, title: "a")
        try forge(id: a.id, index: ["status": "accepted"])
        let re = try MindStore(root: root)
        XCTAssertEqual(try re.audit(), [.statusMismatch(a.id)])
        XCTAssertEqual(try local(re), [])
        XCTAssertEqual(try hosted(re), [])
    }

    func testDotFilesAreNotOrphans() throws {
        let s = try MindStore(root: root)
        try Data().write(to: hitm.appendingPathComponent("entries/.DS_Store"))
        try Data().write(to: hitm.appendingPathComponent("entries/.tmp-abc"))
        XCTAssertEqual(try s.audit(), [])
    }

    func testSupersedeEventLoggedAndPayloadsStartWithId() throws {
        let s = try MindStore(root: root)
        let old = try acceptedAdd(s, title: "old")
        let new = try add(s, title: "new", supersedes: old.id)
        try acc(s, new.id)
        let ev = try logEvents()
        XCTAssertTrue(ev.contains { $0.kind == "supersede" && $0.payload.hasPrefix(old.id) })
        XCTAssertTrue(ev.allSatisfy { e in s.records.contains { e.payload.hasPrefix($0.id) } })
        XCTAssertEqual(try s.audit(), [])
    }

    func testHostedSliceExcludesTamperedChild() throws {
        let s = try MindStore(root: root)
        let a = try acceptedAdd(s, title: "a")
        let b = try acceptedAdd(s, title: "b")
        try appendRaw(" ", to: childURL(b.id))
        XCTAssertEqual(try hosted(s).map(\.id), [a.id])
    }

    // MARK: C. concurrency

    func testConcurrentProposesKeepLogClean() throws {
        let s = try MindStore(root: root)
        let alias = s
        let lock = NSLock()
        nonisolated(unsafe) var ok = 0
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            let store = i % 2 == 0 ? s : alias
            if (try? store.propose(kind: .memory, title: "t\(i)", body: "b", author: "a", sensitive: false)) != nil {
                lock.lock(); ok += 1; lock.unlock()
            }
        }
        XCTAssertEqual(ok, 40)
        XCTAssertEqual(try logEvents().map(\.revision), Array(1...40))
        let re = try MindStore(root: root)
        XCTAssertEqual(re.records.count, 40)
        XCTAssertEqual(try re.audit(), [])
    }

    // MARK: D. approval

    func testApprovalRules() throws {
        let quiet = GateResponse(route: .proceed, needsHuman: false, detailLevel: 0, confidence: 0.9, reason: "ok")
        let unsure = RiskProfile(name: "u", extraHumanRequired: [], unsure: true)
        let sens = RiskProfile(name: "s", extraHumanRequired: [], sensitive: true)
        for h in [nil, "", "  \n "] as [String?] {
            XCTAssertNil(MindPolicy.approve(kind: .policy, entryID: "X", profile: .light, gate: .success(quiet), human: h))
            for p in [RiskProfile.strict, unsure, sens] {
                XCTAssertNil(MindPolicy.approve(kind: .prompt, entryID: "X", profile: p, gate: .success(quiet), human: h))
            }
        }
        let s = try MindStore(root: root)
        let m = try add(s, kind: .memory)
        let p = try add(s, kind: .policy)
        let human = try XCTUnwrap(MindPolicy.approve(kind: .policy, entryID: p.id, profile: .light, gate: nil, human: " Dr X "))
        XCTAssertTrue(human.isHuman)
        XCTAssertEqual(human.approver, "human:Dr X")
        XCTAssertEqual(human.entryID, p.id)
        let auto = try XCTUnwrap(MindPolicy.approve(kind: .memory, entryID: m.id, profile: .light, gate: .success(quiet), human: nil))
        XCTAssertFalse(auto.isHuman)
        XCTAssertEqual(auto.approver, "auto-gate")
        XCTAssertEqual(auto.kind, .memory)

        let wrongKind = try XCTUnwrap(MindPolicy.approve(kind: .prompt, entryID: m.id, profile: .light, gate: nil, human: "h"))
        XCTAssertThrowsError(try s.accept(id: m.id, approval: wrongKind)) { XCTAssertEqual($0 as? MindError, .illegalTransition) }
        let forgedAuto = Approval(kind: .policy, entryID: p.id, approver: "auto-gate", isHuman: false)
        XCTAssertThrowsError(try s.accept(id: p.id, approval: forgedAuto)) { XCTAssertEqual($0 as? MindError, .illegalTransition) }
        XCTAssertEqual(s.record(id: p.id)?.status, .quarantined)
        XCTAssertEqual(try s.accept(id: m.id, approval: auto).status, .accepted)
        XCTAssertEqual(try s.accept(id: p.id, approval: human).status, .accepted)
        XCTAssertTrue(try logEvents().contains { $0.kind == "accept" && $0.payload.contains("auto-gate") })
        XCTAssertTrue(try logEvents().contains { $0.kind == "accept" && $0.payload.contains("human:Dr X") })
    }

    func testApprovalBoundToOneEntry() throws {
        let s = try MindStore(root: root)
        let a = try add(s, title: "a")
        let b = try add(s, title: "b")
        let forA = try XCTUnwrap(MindPolicy.approve(kind: .memory, entryID: a.id, profile: .light, gate: nil, human: "h"))
        XCTAssertThrowsError(try s.accept(id: b.id, approval: forA)) { XCTAssertEqual($0 as? MindError, .illegalTransition) }
        XCTAssertEqual(s.record(id: b.id)?.status, .quarantined)
        XCTAssertEqual(try s.accept(id: a.id, approval: forA).status, .accepted)
        XCTAssertThrowsError(try s.accept(id: b.id, approval: forA)) { XCTAssertEqual($0 as? MindError, .illegalTransition) }
        let lower = try XCTUnwrap(MindPolicy.approve(kind: .memory, entryID: b.id.lowercased(), profile: .light, gate: nil, human: "h"))
        XCTAssertEqual(try s.accept(id: b.id, approval: lower).status, .accepted, "id compare is case-insensitive")
    }

    // MARK: performance

    func timed<T>(_ f: () throws -> T) rethrows -> (T, Double) {
        let t0 = Date(); let r = try f(); return (r, Date().timeIntervalSince(t0))
    }

    func testChainOf40WithParentAndSupersedesIsFast() throws {
        let s = try MindStore(root: root)
        var prev = try acceptedAdd(s, kind: .context, title: "c0")
        var total = 0.0
        for i in 1..<40 {
            let (n, dt1) = try timed { try s.propose(kind: .context, title: "c\(i)", body: "b", author: "t",
                                                   sensitive: false, parentID: prev.id, supersedes: prev.id) }
            let (_, dt2) = try timed { try acc(s, n.id) }
            total += dt1 + dt2
            XCTAssertFalse(n.sensitive)
            prev = s.record(id: n.id)!
        }
        let (h, dt) = try timed { try hosted(s) }
        XCTAssertEqual(h.map(\.title), ["c39"])
        XCTAssertLessThan(total, 5)
        XCTAssertLessThan(dt, 5)
        // a sensitive root taints everything below it
        try wipeAndReopen()
        let s2 = try MindStore(root: root)
        var p = try acceptedAdd(s2, kind: .context, title: "r0", sensitive: true)
        for i in 1..<40 {
            let n = try s2.propose(kind: .context, title: "r\(i)", body: "b", author: "t", sensitive: false,
                                   parentID: p.id, supersedes: p.id)
            XCTAssertTrue(n.sensitive)
            try acc(s2, n.id); p = s2.record(id: n.id)!
        }
        XCTAssertEqual(try hosted(s2), [])
    }

    func wipeAndReopen() throws {
        try FileManager.default.removeItem(at: hitm)
    }

    func testSlicesAndAuditWith300EntriesFastAndReadLogOnce() throws {
        let s = try MindStore(root: root)
        for i in 0..<300 { try acceptedAdd(s, title: "t\(i)", body: "body \(i)") }
        let r0 = s.logReadCount
        let (sl, dt1) = try timed { try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: 1_000_000, destination: .hostedModel) }
        XCTAssertEqual(sl.count, 300)
        XCTAssertEqual(s.logReadCount - r0, 1)
        let r1 = s.logReadCount
        let (f, dt2) = try timed { try s.audit() }
        XCTAssertEqual(f, [])
        XCTAssertEqual(s.logReadCount - r1, 1)
        XCTAssertLessThan(dt1, 2); XCTAssertLessThan(dt2, 2)
    }

    func testThousandEntrySmoke() throws {
        let s = try MindStore(root: root)
        for i in 0..<1000 { try acceptedAdd(s, title: "t\(i)", body: "body \(i)") }
        let (sl, dt1) = try timed { try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: 10_000_000, destination: .hostedModel) }
        let (_, dt2) = try timed { try s.audit() }
        XCTAssertEqual(sl.count, 1000)
        XCTAssertLessThan(dt1 + dt2, 10)
    }

    // MARK: E. small corrections

    func testCorrectAllowedOnSuperseded() throws {
        let s = try MindStore(root: root)
        let old = try acceptedAdd(s, title: "old")
        let new = try add(s, title: "new", supersedes: old.id)
        try acc(s, new.id)
        XCTAssertEqual(s.record(id: old.id)?.status, .superseded)
        XCTAssertEqual(try s.correct(id: old.id, reason: "x", by: "h").status, .corrected)
        XCTAssertEqual(try s.audit(), [])
    }

    func testBudgetWithEmojiAndCombiningMarksCountedInScalars() throws {
        let s = try MindStore(root: root)
        try acceptedAdd(s, title: "e\u{301}", body: String(repeating: "👨‍👩‍👧‍👦 e\u{301}\u{302} ", count: 20))
        try acceptedAdd(s, title: "🏳️‍🌈", body: String(repeating: "a\u{301}\u{308}", count: 30))
        for b in 0...80 {
            let sl = try s.slices(role: "r", kinds: [.memory], tags: [], budgetCharacters: b, destination: .local)
            let total = sl.reduce(0) { $0 + $1.title.unicodeScalars.count + $1.body.unicodeScalars.count }
            XCTAssertLessThanOrEqual(total, b, "budget \(b)")
        }
    }
}
