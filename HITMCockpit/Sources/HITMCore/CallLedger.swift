import Foundation
import CryptoKit

public enum LedgerError: Error, Equatable, Sendable {
    case budgetExceeded(String)
    /// An earlier call has an intent but no receipt: its outcome is unknown, so nothing new is sent until a person reconciles it.
    case unresolvedCall(String)
    case ioFailure
}

public struct LedgerLimits: Equatable, Sendable {
    public let maxCalls: Int
    /// Applies to KNOWN cost only; a call whose cost was not reported is counted separately, never as zero.
    public let maxKnownCostUSD: Double
    public init(maxCalls: Int, maxKnownCostUSD: Double) { self.maxCalls = maxCalls; self.maxKnownCostUSD = maxKnownCostUSD }
    public static let perRun = LedgerLimits(maxCalls: 6, maxKnownCostUSD: 0.25)
}

public struct LedgerEntry: Codable, Equatable, Sendable {
    /// "intent" before a call, "receipt" after it, "reconcile" when a person settles an unresolved call.
    public let kind: String
    public let callID: String
    public let at: Date
    public let role: String?
    public let model: String?
    public let inputSHA256: String?
    public let maxTokens: Int?
    public let outcome: String?
    public let httpStatus: Int?
    public let latencyMs: Int?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let costUSD: Double?
    public let usedModel: String?
    public let note: String?
}

public struct LedgerUsage: Equatable, Sendable {
    public let calls: Int
    public let knownCostUSD: Double
    /// Calls that reported no cost (including unresolved ones). Unknown stays unknown.
    public let callsWithUnknownCost: Int
    public let unresolved: [String]
}

/// Append-only record of every paid call: an intent line BEFORE the call, a receipt AFTER it. Caps are derived from the
/// file, so they survive a restart. Holds no request body, response body or key. Single writer.
public final class CallLedger: @unchecked Sendable {
    public let fileURL: URL
    public let limits: LedgerLimits
    private let lock = NSLock()

    public init(fileURL: URL, limits: LedgerLimits = .perRun) { self.fileURL = fileURL; self.limits = limits }

    public static func sha256Hex(_ parts: [String]) -> String {
        var h = SHA256()
        for p in parts { h.update(data: Data(p.utf8)); h.update(data: Data([0])) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    public func entries() throws -> [LedgerEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { throw LedgerError.ioFailure }
        // A line that does not decode is an integrity problem; fail closed rather than skip it.
        return try String(decoding: data, as: UTF8.self).split(separator: "\n").map { line in
            do { return try Self.decoder().decode(LedgerEntry.self, from: Data(line.utf8)) } catch { throw LedgerError.ioFailure }
        }
    }

    public func usage() throws -> LedgerUsage { Self.usage(of: try entries()) }

    static func usage(of all: [LedgerEntry]) -> LedgerUsage {
        let intents = all.filter { $0.kind == "intent" }
        let receipts = Dictionary(all.filter { $0.kind == "receipt" }.map { ($0.callID, $0) }, uniquingKeysWith: { _, b in b })
        let reconciled = Set(all.filter { $0.kind == "reconcile" }.map(\.callID))
        var cost = 0.0, unknown = 0
        var unresolved: [String] = []
        for i in intents {
            if let r = receipts[i.callID] {
                if let c = r.costUSD, c.isFinite, c >= 0 { cost += c } else { unknown += 1 }
            } else {
                unknown += 1
                if !reconciled.contains(i.callID) { unresolved.append(i.callID) }
            }
        }
        return LedgerUsage(calls: intents.count, knownCostUSD: cost, callsWithUnknownCost: unknown, unresolved: unresolved)
    }

    private func append(_ e: LedgerEntry) throws {
        var line = try Self.encoder().encode(e)
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) { guard fm.createFile(atPath: fileURL.path, contents: nil) else { throw LedgerError.ioFailure } }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { throw LedgerError.ioFailure }
        defer { try? h.close() }
        do { try h.seekToEnd(); try h.write(contentsOf: line); try h.synchronize() } catch { throw LedgerError.ioFailure }
    }

    private func entry(kind: String, callID: String, role: String? = nil, model: String? = nil, input: String? = nil,
                       maxTokens: Int? = nil, record: CallRecord? = nil, note: String? = nil) -> LedgerEntry {
        LedgerEntry(kind: kind, callID: callID, at: Date(), role: role, model: model, inputSHA256: input, maxTokens: maxTokens,
                    outcome: record?.outcome, httpStatus: record?.httpStatus, latencyMs: record?.latencyMs,
                    promptTokens: record?.promptTokens, completionTokens: record?.completionTokens,
                    costUSD: record?.costUSD, usedModel: record?.usedModel, note: note)
    }

    /// Writes the intent line, or throws before anything is sent when a cap is reached or an earlier call is unresolved.
    public func begin(role: String, model: String, inputSHA256: String, maxTokens: Int?) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let u = try usage()
        if let first = u.unresolved.first { throw LedgerError.unresolvedCall(first) }
        if u.calls >= limits.maxCalls { throw LedgerError.budgetExceeded("calls") }
        if u.knownCostUSD >= limits.maxKnownCostUSD { throw LedgerError.budgetExceeded("cost") }
        let id = UUID().uuidString.lowercased()
        try append(entry(kind: "intent", callID: id, role: role, model: model, input: inputSHA256, maxTokens: maxTokens))
        return id
    }

    public func finish(callID: String, record: CallRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try append(entry(kind: "receipt", callID: callID, record: record))
    }

    /// A person settles an unresolved call (for example "executed" or "not_executed") so the ledger can continue.
    public func reconcile(callID: String, as resolution: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard try usage().unresolved.contains(callID) else { throw LedgerError.ioFailure }
        try append(entry(kind: "reconcile", callID: callID, note: resolution))
    }

    /// Intent, then the call, then the receipt. If the process dies in between, the intent stays unresolved.
    public func run<T: Sendable>(role: String, model: String, inputSHA256: String, maxTokens: Int?,
                                 call: @Sendable () async -> (T, CallRecord?)) async throws -> T {
        let id = try begin(role: role, model: model, inputSHA256: inputSHA256, maxTokens: maxTokens)
        let (value, record) = await call()
        let rec = record ?? CallRecord(requestedModel: model, usedModel: nil, httpStatus: nil, latencyMs: 0,
                                       promptTokens: nil, completionTokens: nil, costUSD: nil, outcome: "no-call-made")
        try finish(callID: id, record: rec)
        return value
    }
}
