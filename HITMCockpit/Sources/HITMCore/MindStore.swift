import Foundation
import CryptoKit

/// File-backed shared mind under `<root>/.hitm/`:
///   mind.json         parent index (records with status and child sha256)
///   entries/<id>.json immutable child files
///   log.jsonl         append-only, one `Event` JSON per line; revisions strictly increase.
///                     Payloads start with the entry id ("<id> ...").
///
/// Threads: a final class guarded by one lock, so all references to a store see one state.
/// MULTI-PROCESS writers are still UNSUPPORTED (no file lock; deferred): two processes writing the
/// same `.hitm` can lose updates. Writes are atomic (temp file in the same directory, then rename);
/// a child file is written BEFORE the index references it, the index before the log event. A crash
/// (or log failure) between index and log shows up in `audit()` as statusMismatch / noLogEvent.
public final class MindStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private let sessionID = UUID()
    private var _records: [MindRecord]
    private var lastRevision: Int
    private var _logReads = 0
    /// Number of full log reads so far (test hook for the one-read-per-call guarantee).
    var logReadCount: Int { lock.lock(); defer { lock.unlock() }; return _logReads }

    public var records: [MindRecord] { lock.lock(); defer { lock.unlock() }; return _records }

    private struct IndexFile: Codable { var version: Int; var entries: [MindRecord] }

    private static func norm(_ id: String) -> String { id.uppercased() }
    private var dir: URL { root.appendingPathComponent(".hitm", isDirectory: true) }
    private var entriesDir: URL { dir.appendingPathComponent("entries", isDirectory: true) }
    private var indexURL: URL { dir.appendingPathComponent("mind.json") }
    private var logURL: URL { dir.appendingPathComponent("log.jsonl") }

    public init(root: URL) throws {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(".hitm", isDirectory: true)
        let indexURL = dir.appendingPathComponent("mind.json")
        let logURL = dir.appendingPathComponent("log.jsonl")
        do { try fm.createDirectory(at: dir.appendingPathComponent("entries", isDirectory: true),
                                    withIntermediateDirectories: true) }
        catch { throw MindError.ioFailure("create directories") }
        if !fm.fileExists(atPath: indexURL.path) {
            try Self.atomicWrite(try Self.encodeIndex([]), to: indexURL)
        }
        guard let indexData = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(IndexFile.self, from: indexData)
        else { throw MindError.integrityFailure }
        var ids = Set<String>()
        for r in index.entries {
            // Ids become file names: only UUID strings, unique ignoring case (no path traversal).
            guard UUID(uuidString: r.id) != nil, ids.insert(Self.norm(r.id)).inserted
            else { throw MindError.integrityFailure }
        }
        for r in index.entries {
            for link in [r.parentID, r.supersedes].compactMap({ $0 }) where !ids.contains(Self.norm(link)) {
                throw MindError.integrityFailure
            }
        }
        // Log: never silently recreate it when the index has entries.
        if !fm.fileExists(atPath: logURL.path) {
            guard index.entries.isEmpty else { throw MindError.integrityFailure }
            try Self.atomicWrite(Data(), to: logURL)
        }
        guard let logData = try? Data(contentsOf: logURL) else { throw MindError.integrityFailure }
        var good: [Data] = []
        var last = 0
        var torn = false
        let lines = logData.split(separator: UInt8(ascii: "\n")).map { Data($0) }
            .filter { !String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for (i, line) in lines.enumerated() {
            if let e = try? JSONDecoder().decode(Event.self, from: line), e.revision > last {
                last = e.revision; good.append(line)
            } else if i == lines.count - 1 {
                torn = true        // a single unparseable FINAL line is a torn write: drop it
            } else {
                throw MindError.integrityFailure
            }
        }
        if !index.entries.isEmpty && good.isEmpty { throw MindError.integrityFailure }
        if torn || (!logData.isEmpty && logData.last != UInt8(ascii: "\n")) {
            var clean = Data()
            for l in good { clean.append(l); clean.append(UInt8(ascii: "\n")) }
            try Self.atomicWrite(clean, to: logURL)
        }
        self.root = root
        self._records = index.entries
        self.lastRevision = max(last, index.entries.map(\.createdRevision).max() ?? 0)
    }

    public func record(id: String) -> MindRecord? { lock.lock(); defer { lock.unlock() }; return lookup(id) }

    // MARK: propose and transitions

    @discardableResult
    public func propose(kind: MindKind, title: String, body: String, tags: [String] = [],
                        role: String? = nil, evidence: [String] = [], author: String,
                        sensitive: Bool, parentID: String? = nil,
                        supersedes: String? = nil) throws -> MindRecord {
        lock.lock(); defer { lock.unlock() }
        let cleanTitle = Self.singleLine(title, cap: 120)
        let cleanBody = Self.cleanBody(body, cap: 20_000)
        let cleanAuthor = Self.singleLine(author, cap: 80)
        guard !cleanTitle.isEmpty, !cleanBody.isEmpty, !cleanAuthor.isEmpty else { throw MindError.invalidEntry }
        if let p = parentID, lookup(p) == nil { throw MindError.invalidEntry }
        var isSensitive = sensitive
        if let s = supersedes {
            guard let old = lookup(s) else { throw MindError.invalidEntry }
            // A replacement inherits sensitivity from what it replaces (fail closed if that is unverifiable).
            if tainted(old, Ctx()) { isSensitive = true }
        }
        var cleanTags: [String] = []
        for t in tags.map({ Self.singleLine($0, cap: 40) }) where !t.isEmpty && !cleanTags.contains(t) {
            cleanTags.append(t)
            if cleanTags.count == 10 { break }
        }
        let cleanRole = role.map { Self.singleLine($0, cap: 40) }.flatMap { $0.isEmpty ? nil : $0 }
        let cleanEvidence = Array(evidence.map { Self.singleLine($0, cap: 300) }.filter { !$0.isEmpty }.prefix(10))

        let id = UUID().uuidString
        let revision = lastRevision + 1
        let entry = MindEntry(id: id, kind: kind, title: cleanTitle, body: cleanBody, tags: cleanTags,
                              author: cleanAuthor, createdRevision: revision, evidence: cleanEvidence,
                              sensitive: isSensitive, parentID: parentID, supersedes: supersedes, role: cleanRole)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let bytes: Data
        do { bytes = try enc.encode(entry) } catch { throw MindError.ioFailure("encode entry") }
        let record = MindRecord(id: id, kind: kind, status: .quarantined, author: cleanAuthor,
                                sensitive: isSensitive, createdRevision: revision, supersedes: supersedes,
                                parentID: parentID, role: cleanRole, tags: cleanTags, sha256: Self.sha256Hex(bytes))
        try Self.atomicWrite(bytes, to: childURL(id))                    // child first
        try Self.atomicWrite(try Self.encodeIndex(_records + [record]), to: indexURL)
        _records.append(record)
        do { try appendLog(kind: "propose", payload: id, author: cleanAuthor) }
        catch { lastRevision = revision; throw error }   // the index already holds this revision
        return record
    }

    @discardableResult
    public func accept(id: String, approval: Approval) throws -> MindRecord {
        lock.lock(); defer { lock.unlock() }
        let rec = try requireRecord(id)
        guard approval.kind == rec.kind, Self.norm(approval.entryID) == Self.norm(rec.id) else { throw MindError.illegalTransition }
        if rec.kind == .policy && !approval.isHuman { throw MindError.illegalTransition }
        guard rec.status == .quarantined else { throw MindError.illegalTransition }
        var updated = _records
        var supersededID: String?
        if let old = rec.supersedes, let oi = updated.firstIndex(where: { Self.norm($0.id) == Self.norm(old) }),
           updated[oi].status == .accepted {
            updated[oi].status = .superseded    // old child stays on disk
            supersededID = updated[oi].id
        }
        let result = try commit(&updated, id: id, to: .accepted)
        try appendLog(kind: "accept", payload: "\(rec.id) by \(approval.approver)", author: approval.approver)
        if let old = supersededID {
            try appendLog(kind: "supersede", payload: "\(old) by \(rec.id)", author: approval.approver)
        }
        return result
    }

    @discardableResult
    public func reject(id: String, by: String, reason: String) throws -> MindRecord {
        lock.lock(); defer { lock.unlock() }
        let rec = try requireRecord(id)
        guard rec.status == .quarantined else { throw MindError.illegalTransition }
        var updated = _records
        let result = try commit(&updated, id: id, to: .rejected)
        try appendLog(kind: "reject", payload: "\(rec.id) \(Self.singleLine(reason, cap: 300))", author: by)
        return result
    }

    @discardableResult
    public func expire(id: String, by: String) throws -> MindRecord {
        lock.lock(); defer { lock.unlock() }
        let rec = try requireRecord(id)
        guard rec.status == .accepted else { throw MindError.illegalTransition }
        var updated = _records
        let result = try commit(&updated, id: id, to: .expired)
        try appendLog(kind: "expire", payload: rec.id, author: by)
        return result
    }

    /// Deletion is a recorded correction: the child file is never edited or removed.
    @discardableResult
    public func correct(id: String, reason: String, by: String) throws -> MindRecord {
        lock.lock(); defer { lock.unlock() }
        let rec = try requireRecord(id)
        guard rec.status == .accepted || rec.status == .quarantined || rec.status == .superseded
        else { throw MindError.illegalTransition }
        var updated = _records
        let result = try commit(&updated, id: id, to: .corrected)
        try appendLog(kind: "correction", payload: "\(rec.id) \(Self.singleLine(reason, cap: 300))", author: by)
        return result
    }

    // MARK: reading

    public func children(of id: String) throws -> [MindRecord] {
        lock.lock(); defer { lock.unlock() }
        let parent = try requireRecord(id)
        return _records.filter { $0.parentID.map(Self.norm) == Self.norm(parent.id) }
            .sorted { $0.createdRevision < $1.createdRevision }
    }

    public func audit() throws -> [AuditFinding] {
        lock.lock(); defer { lock.unlock() }
        var findings: [AuditFinding] = _records.filter { verifiedEntry($0) == nil }.map { .untrusted($0.id) }
        let log = readLogIndex()      // one log read per audit call
        for r in _records {
            if let f = logFinding(r, log) { findings.append(f) }
        }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: entriesDir.path) }
        catch { throw MindError.ioFailure("list entries") }
        let known = Set(_records.map { "\(Self.norm($0.id)).JSON" })
        findings += names.filter { !$0.hasPrefix(".") && !known.contains($0.uppercased()) }
            .sorted().map { .orphan($0) }
        return findings
    }

    public func slices(role: String, kinds: Set<MindKind>, tags: [String], budgetCharacters: Int,
                       destination: MindDestination) throws -> [MindSlice] {
        lock.lock(); defer { lock.unlock() }
        guard budgetCharacters > 0 else { return [] }
        let wanted = Set(tags)
        let log = readLogIndex()      // one log read per slices call
        let ctx = Ctx()               // each child file verified at most once per call
        var out: [MindSlice] = []
        var remaining = budgetCharacters
        let candidates = _records
            .filter { $0.status == .accepted && kinds.contains($0.kind) }
            .filter { $0.role == nil || $0.role == role }
            .filter { wanted.isEmpty || !wanted.isDisjoint(with: $0.tags) }
            .filter { logFinding($0, log) == nil }                       // log disagrees with index: excluded
            .filter { destination == .local || !tainted($0, ctx) }
            .sorted { $0.createdRevision > $1.createdRevision }
        for rec in candidates {
            guard let entry = verify(rec, ctx) else { continue }   // untrusted: excluded
            if destination == .hostedModel && (rec.sensitive || entry.sensitive) { continue }
            let titleLen = entry.title.unicodeScalars.count
            let bodyLen = entry.body.unicodeScalars.count
            if titleLen + bodyLen <= remaining {
                out.append(MindSlice(id: rec.id, kind: rec.kind, title: entry.title, body: entry.body, tags: rec.tags))
                remaining -= titleLen + bodyLen
                if remaining == 0 { break }
            } else {
                // The budget is counted in Unicode scalars; cutting there may split a grapheme cluster
                // (emoji sequence, combining mark). That is cosmetic; the budget is never exceeded.
                let room = remaining - titleLen - 1       // 1 for the ellipsis
                if room >= 0 {
                    var v = String.UnicodeScalarView()
                    v.append(contentsOf: entry.body.unicodeScalars.prefix(room))
                    out.append(MindSlice(id: rec.id, kind: rec.kind, title: entry.title,
                                         body: String(v) + "…", tags: rec.tags))
                }
                break
            }
        }
        return out
    }

    // MARK: internals (callers hold the lock)

    private func childURL(_ id: String) -> URL { entriesDir.appendingPathComponent("\(id).json") }

    private func lookup(_ id: String) -> MindRecord? {
        _records.first { Self.norm($0.id) == Self.norm(id) }
    }

    private func requireRecord(_ id: String) throws -> MindRecord {
        guard let r = lookup(id) else { throw MindError.unknownEntry }
        return r
    }

    private func commit(_ updated: inout [MindRecord], id: String, to status: MindStatus) throws -> MindRecord {
        guard let i = updated.firstIndex(where: { Self.norm($0.id) == Self.norm(id) }) else { throw MindError.unknownEntry }
        updated[i].status = status
        try Self.atomicWrite(try Self.encodeIndex(updated), to: indexURL)
        _records = updated
        return updated[i]
    }

    /// The decoded child, only if its bytes match the index hash AND its metadata matches the index record.
    private func verifiedEntry(_ rec: MindRecord) -> MindEntry? {
        guard let data = try? Data(contentsOf: childURL(rec.id)), Self.sha256Hex(data) == rec.sha256,
              let e = try? JSONDecoder().decode(MindEntry.self, from: data),
              Self.norm(e.id) == Self.norm(rec.id), e.kind == rec.kind, e.sensitive == rec.sensitive,
              e.parentID == rec.parentID, e.supersedes == rec.supersedes, e.role == rec.role,
              e.tags == rec.tags else { return nil }
        return e
    }

    /// Per-call cache: each child file is read and hash-verified at most once per traversal/call.
    private final class Ctx {
        var entries: [String: MindEntry?] = [:]
        var clean: Set<String> = []
    }

    private func verify(_ rec: MindRecord, _ ctx: Ctx) -> MindEntry? {
        let key = Self.norm(rec.id)
        if let cached = ctx.entries[key] { return cached }
        let e = verifiedEntry(rec)
        ctx.entries[key] = .some(e)
        return e
    }

    /// True when the entry, or anything reachable through parent or supersedes links, is sensitive,
    /// unverifiable, missing, or part of a cycle. Fail closed. Iterative depth-first walk (no recursion,
    /// so no exponential blow-up on parent+supersedes chains); finished clean nodes are remembered.
    private func tainted(_ root: MindRecord, _ ctx: Ctx) -> Bool {
        var stack: [(rec: MindRecord, links: [String], next: Int)] = []
        var onStack = Set<String>()
        func push(_ rec: MindRecord) -> Bool {
            let key = Self.norm(rec.id)
            if ctx.clean.contains(key) { return true }
            if onStack.contains(key) || rec.sensitive { return false }   // cycle, or sensitive
            guard let e = verify(rec, ctx), !e.sensitive else { return false }
            onStack.insert(key)
            stack.append((rec, [rec.parentID, rec.supersedes].compactMap { $0 }, 0))
            return true
        }
        if !push(root) { return true }
        while var top = stack.popLast() {
            if top.next < top.links.count {
                let link = top.links[top.next]
                top.next += 1
                stack.append(top)
                guard let next = lookup(link) else { return true }       // unresolvable link
                if !push(next) { return true }
            } else {
                let key = Self.norm(top.rec.id)
                onStack.remove(key)
                ctx.clean.insert(key)
            }
        }
        return false
    }

    private struct LogIndex {
        var proposed: Set<String> = []
        var implied: [String: MindStatus] = [:]
    }

    /// Replays the log once: the latest event per id implies a status.
    /// Recovery gap (known, NOT implemented): a torn or lost accept/propose event leaves the entry as
    /// statusMismatch / noLogEvent, which only expire/correct can clear; there is no repair or log rebuild.
    private func readLogIndex() -> LogIndex {
        _logReads += 1
        var idx = LogIndex()
        for line in ((try? Data(contentsOf: logURL)) ?? Data()).split(separator: UInt8(ascii: "\n")) {
            guard let e = try? JSONDecoder().decode(Event.self, from: Data(line)),
                  let token = e.payload.split(separator: " ").first else { continue }
            let key = Self.norm(String(token))
            switch e.kind {
            case "propose": idx.proposed.insert(key); idx.implied[key] = .quarantined
            case "accept": idx.implied[key] = .accepted
            case "reject": idx.implied[key] = .rejected
            case "expire": idx.implied[key] = .expired
            case "correction": idx.implied[key] = .corrected
            case "supersede": idx.implied[key] = .superseded
            default: break
            }
        }
        return idx
    }

    private func logFinding(_ rec: MindRecord, _ log: LogIndex) -> AuditFinding? {
        let key = Self.norm(rec.id)
        if !log.proposed.contains(key) { return .noLogEvent(rec.id) }
        return log.implied[key] == rec.status ? nil : .statusMismatch(rec.id)
    }

    private func appendLog(kind: String, payload: String, author: String) throws {
        let event = Event(sessionID: sessionID, revision: lastRevision + 1, kind: kind, payload: payload,
                          author: Self.singleLine(author, cap: 80))
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard var line = try? enc.encode(event) else { throw MindError.ioFailure("encode event") }
        line.append(UInt8(ascii: "\n"))
        do {
            let h = try FileHandle(forWritingTo: logURL)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } catch { throw MindError.ioFailure("append log") }
        lastRevision = event.revision
    }

    private static func encodeIndex(_ entries: [MindRecord]) throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        do { return try enc.encode(IndexFile(version: 1, entries: entries)) }
        catch { throw MindError.ioFailure("encode index") }
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: url) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw MindError.ioFailure("write \(url.lastPathComponent)")
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whitespace collapsed to single spaces; control and format characters removed; trimmed; capped.
    static func singleLine(_ raw: String, cap: Int) -> String {
        var v = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            if u.properties.isWhitespace { v.append(" "); continue }
            switch u.properties.generalCategory {
            case .control, .format: continue
            default: v.append(u)
            }
        }
        let collapsed = String(v).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return capped(collapsed, cap)
    }

    /// Control characters removed except newline and tab; format characters removed; trimmed; capped.
    static func cleanBody(_ raw: String, cap: Int) -> String {
        var v = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            if u == "\n" || u == "\t" { v.append(u); continue }
            switch u.properties.generalCategory {
            case .control, .format: continue
            default: v.append(u)
            }
        }
        return capped(String(v).trimmingCharacters(in: .whitespacesAndNewlines), cap)
    }

    private static func capped(_ s: String, _ cap: Int) -> String {
        guard s.unicodeScalars.count > cap else { return s }
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s.unicodeScalars.prefix(cap))
        return String(v)
    }
}
