import XCTest
@testable import HITMCore

final class CallLedgerTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)/ledger.jsonl")
    }
    static func rec(cost: Double?, outcome: String = "ok") -> CallRecord {
        CallRecord(requestedModel: "m", usedModel: "m", httpStatus: 200, latencyMs: 5, promptTokens: 1, completionTokens: 1,
                   costUSD: cost, outcome: outcome)
    }

    func testIntentIsWrittenBeforeTheCallAndReceiptAfter() async throws {
        let url = tempFile()
        let ledger = CallLedger(fileURL: url, limits: LedgerLimits(maxCalls: 3, maxKnownCostUSD: 1))
        let seenDuringCall = ledger // inspected from inside the call
        let value: Int = try await ledger.run(role: "planner", model: "m", inputSHA256: "abc", maxTokens: 10) {
            let kinds = ((try? seenDuringCall.entries()) ?? []).map(\.kind)
            XCTAssertEqual(kinds, ["intent"])
            return (7, CallLedgerTests.rec(cost: 0.01))
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(try ledger.entries().map(\.kind), ["intent", "receipt"])
        let u = try ledger.usage()
        XCTAssertEqual(u.calls, 1); XCTAssertEqual(u.knownCostUSD, 0.01, accuracy: 1e-9); XCTAssertTrue(u.unresolved.isEmpty)
    }

    func testCallCapRefusesBeforeAnyIntentIsWritten() async throws {
        let ledger = CallLedger(fileURL: tempFile(), limits: LedgerLimits(maxCalls: 2, maxKnownCostUSD: 1))
        for _ in 0..<2 { _ = try await ledger.run(role: "r", model: "m", inputSHA256: "h", maxTokens: nil) { (0, CallLedgerTests.rec(cost: 0)) } }
        let before = try ledger.entries().count
        do { _ = try await ledger.run(role: "r", model: "m", inputSHA256: "h", maxTokens: nil) { (0, CallLedgerTests.rec(cost: 0)) }; XCTFail("expected refusal") }
        catch { XCTAssertEqual(error as? LedgerError, .budgetExceeded("calls")) }
        XCTAssertEqual(try ledger.entries().count, before)
    }

    func testKnownCostCapRefuses() async throws {
        let ledger = CallLedger(fileURL: tempFile(), limits: LedgerLimits(maxCalls: 10, maxKnownCostUSD: 0.05))
        _ = try await ledger.run(role: "r", model: "m", inputSHA256: "h", maxTokens: nil) { (0, CallLedgerTests.rec(cost: 0.05)) }
        do { _ = try await ledger.run(role: "r", model: "m", inputSHA256: "h", maxTokens: nil) { (0, CallLedgerTests.rec(cost: 0)) }; XCTFail("expected refusal") }
        catch { XCTAssertEqual(error as? LedgerError, .budgetExceeded("cost")) }
    }

    func testUnknownCostStaysUnknownAndIsNotCountedAsZero() async throws {
        let ledger = CallLedger(fileURL: tempFile(), limits: LedgerLimits(maxCalls: 5, maxKnownCostUSD: 1))
        _ = try await ledger.run(role: "r", model: "m", inputSHA256: "h", maxTokens: nil) { (0, CallLedgerTests.rec(cost: nil)) }
        let u = try ledger.usage()
        XCTAssertEqual(u.callsWithUnknownCost, 1); XCTAssertEqual(u.knownCostUSD, 0)
    }

    func testIntentWithoutReceiptBlocksNewCallsUntilReconciled() throws {
        let ledger = CallLedger(fileURL: tempFile(), limits: LedgerLimits(maxCalls: 5, maxKnownCostUSD: 1))
        let id = try ledger.begin(role: "r", model: "m", inputSHA256: "h", maxTokens: nil)   // process "dies" here
        XCTAssertThrowsError(try ledger.begin(role: "r", model: "m", inputSHA256: "h", maxTokens: nil)) {
            XCTAssertEqual($0 as? LedgerError, .unresolvedCall(id))
        }
        try ledger.reconcile(callID: id, as: "not_executed")
        XCTAssertNoThrow(try ledger.begin(role: "r", model: "m", inputSHA256: "h", maxTokens: nil))
        XCTAssertEqual(try ledger.usage().calls, 2)   // the unresolved call still counts toward the cap
    }

    func testStateSurvivesANewInstanceOnTheSameFile() throws {
        let url = tempFile()
        let a = CallLedger(fileURL: url, limits: LedgerLimits(maxCalls: 1, maxKnownCostUSD: 1))
        let id = try a.begin(role: "r", model: "m", inputSHA256: "h", maxTokens: nil)
        try a.finish(callID: id, record: CallLedgerTests.rec(cost: 0))
        let b = CallLedger(fileURL: url, limits: LedgerLimits(maxCalls: 1, maxKnownCostUSD: 1))
        XCTAssertThrowsError(try b.begin(role: "r", model: "m", inputSHA256: "h", maxTokens: nil)) {
            XCTAssertEqual($0 as? LedgerError, .budgetExceeded("calls"))
        }
    }

    func testCorruptLineFailsClosed() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json\n".utf8).write(to: url)
        let ledger = CallLedger(fileURL: url)
        XCTAssertThrowsError(try ledger.begin(role: "r", model: "m", inputSHA256: "h", maxTokens: nil))
    }

    func testLedgerHoldsNoBodyOrKey() async throws {
        let url = tempFile()
        let ledger = CallLedger(fileURL: url)
        _ = try await ledger.run(role: "r", model: "m", inputSHA256: CallLedger.sha256Hex(["secret prompt text"]), maxTokens: 5) { (0, CallLedgerTests.rec(cost: 0)) }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains("secret prompt text"))
        XCTAssertFalse(text.lowercased().contains("bearer"))
    }
}
