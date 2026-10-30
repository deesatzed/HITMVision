import Foundation
import CryptoKit

public enum RuleStoreError: Error, Equatable, Sendable {
    /// No non-blank human name was given, so no approval exists. Rules are never activated automatically.
    case humanApprovalRequired
    /// The approver's name equals the proposal's author.
    case approverIsAuthor
    case unknownRule
    /// An allow rule wider than its family's ceiling.
    case aboveCeiling
    case notWider
    /// A rule with that id already has an active or waiting (quarantined) entry.
    case duplicateRuleID
    /// A project or folder rule without a `projectID` could never apply.
    case missingProjectID
    /// The rule could not be stored exactly as given.
    case unstorable
    /// A widening of this rule is already waiting for a decision.
    case changePending
}

/// How many standing-rule entries are accepted but could not be verified or decoded. Any above zero means
/// a rule (possibly an ask rule) is missing from the readable set.
public struct RuleStoreHealth: Equatable, Sendable {
    public let untrustedEntryCount: Int
}

/// Standing rules as `policy` entries in the shared mind (R8): quarantined when proposed, active only after
/// a named human accepts, widening is a new superseding proposal, revoking expires every active entry for the
/// rule id. Reading is fail closed: an entry that does not verify or does not decode strictly is left out of
/// `activeRules()` AND counted in `health()`; `ruleBook` then asks for everything.
///
/// The engine cannot tell a person from a string. The future UI MUST call `accept` only from a person's
/// own action (a tap on an approval control), never from agent output, a script or a stored default.
/// Writes that check then change state hold one lock, shared by every store in the process. Multi-process
/// writers remain unsupported, as in `MindStore`.
public final class RuleStore: @unchecked Sendable {
    public let mind: MindStore

    static let tag = "standing-rule"
    private static let readRole = "rules"
    private static let writeLock = NSRecursiveLock()

    public init(mind: MindStore) { self.mind = mind }

    static func ridTag(_ ruleID: String) -> String {
        let digest = SHA256.hash(data: Data(ruleID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "rid:" + digest.prefix(32)      // 36 characters, inside the mind's 40-character tag cap
    }

    static func encode(_ rule: Rule) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(rule) else { throw RuleStoreError.unstorable }
        let body = String(decoding: data, as: UTF8.self)
        // The mind cleans bodies; a rule must come back exactly as written or not be stored at all.
        guard MindStore.cleanBody(body, cap: 20_000) == body else { throw RuleStoreError.unstorable }
        return body
    }

    private static func decode(_ body: String) -> Rule? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Rule.self, from: Data(body.utf8))
    }

    private static func check(_ rule: Rule) throws {
        if rule.effect == .allow, rule.scope.level > CommandFamilies.family(rule.family).ceiling {
            throw RuleStoreError.aboveCeiling
        }
        switch rule.scope {
        case .project, .projectFolder: if rule.projectID == nil { throw RuleStoreError.missingProjectID }
        case .session, .all: break
        }
    }

    /// Policy entries for this rule id that are active or waiting, whether or not their files verify.
    private func records(forRuleID id: String, in statuses: Set<MindStatus>) -> [MindRecord] {
        let t = Self.ridTag(id)
        return mind.records.filter { $0.kind == .policy && $0.tags.contains(t) && statuses.contains($0.status) }
    }

    /// Writes a quarantined policy entry. Sensitivity follows the profile (`isSensitive`), so rules written
    /// under strict-unsure-or-sensitive settings never reach a hosted model.
    @discardableResult
    public func propose(rule: Rule, author: String, profile: RiskProfile) throws -> MindRecord {
        Self.writeLock.lock(); defer { Self.writeLock.unlock() }
        try Self.check(rule)
        if !records(forRuleID: rule.id, in: [.quarantined, .accepted]).isEmpty { throw RuleStoreError.duplicateRuleID }
        return try write(rule, author: author, profile: profile, supersedes: nil)
    }

    private func write(_ rule: Rule, author: String, profile: RiskProfile, supersedes: String?) throws -> MindRecord {
        try mind.propose(kind: .policy, title: "Standing rule \(rule.id)", body: try Self.encode(rule),
                         tags: [Self.tag, Self.ridTag(rule.id)], author: author, sensitive: profile.isSensitive,
                         supersedes: supersedes)
    }

    /// Needs a named human who is not the proposal's author. `MindPolicy.approve` returns nil without a name.
    @discardableResult
    public func accept(recordID: String, profile: RiskProfile, human: String?) throws -> MindRecord {
        Self.writeLock.lock(); defer { Self.writeLock.unlock() }
        guard let approval = MindPolicy.approve(kind: .policy, entryID: recordID, profile: profile, gate: nil, human: human)
        else { throw RuleStoreError.humanApprovalRequired }
        guard let rec = mind.record(id: recordID) else { throw MindError.unknownEntry }
        let approver = MindStore.singleLine(human ?? "", cap: 80).lowercased()
        if approver == MindStore.singleLine(rec.author, cap: 80).lowercased() { throw RuleStoreError.approverIsAuthor }
        return try mind.accept(id: recordID, approval: approval)
    }

    /// A new entry that supersedes the active one once accepted. The old rule keeps working until then.
    @discardableResult
    public func widen(ruleID: String, to scope: RuleScope, author: String, profile: RiskProfile) throws -> MindRecord {
        Self.writeLock.lock(); defer { Self.writeLock.unlock() }
        guard let old = try activeEntries().first(where: { $0.rule.id == ruleID }) else { throw RuleStoreError.unknownRule }
        if !records(forRuleID: ruleID, in: [.quarantined]).isEmpty { throw RuleStoreError.changePending }
        guard scope.level > old.rule.scope.level else { throw RuleStoreError.notWider }
        let wider = Rule(id: old.rule.id, family: old.rule.family, command: old.rule.command,
                         subcommand: old.rule.subcommand, scope: scope, effect: old.rule.effect,
                         projectID: old.rule.projectID, enabledForProjects: old.rule.enabledForProjects,
                         expiresAt: old.rule.expiresAt)
        try Self.check(wider)
        return try write(wider, author: author, profile: profile, supersedes: old.recordID)
    }

    /// Expires EVERY active entry for the rule id, including ones that no longer verify. Revoking an allow rule
    /// tightens policy and stays open. Revoking an ask rule (or one that cannot be read, which might be one)
    /// loosens policy: it needs a named human who is not the author of any of its entries.
    public func revoke(ruleID: String, by: String) throws {
        Self.writeLock.lock(); defer { Self.writeLock.unlock() }
        let active = records(forRuleID: ruleID, in: [.accepted])
        guard !active.isEmpty else { throw RuleStoreError.unknownRule }
        var effectByRecord: [String: RuleEffect] = [:]
        for e in try readable() { effectByRecord[e.recordID.uppercased()] = e.rule.effect }
        if active.contains(where: { (effectByRecord[$0.id.uppercased()] ?? .ask) == .ask }) {
            let name = MindStore.singleLine(by, cap: 80).lowercased()
            guard !name.isEmpty else { throw RuleStoreError.humanApprovalRequired }
            if active.contains(where: { MindStore.singleLine($0.author, cap: 80).lowercased() == name }) {
                throw RuleStoreError.approverIsAuthor
            }
        }
        for rec in active { try mind.expire(id: rec.id, by: by) }
    }

    /// Every accepted standing-rule entry that verifies and decodes, newest first.
    private func readable() throws -> [(recordID: String, rule: Rule)] {
        let slices = try mind.slices(role: Self.readRole, kinds: [.policy], tags: [Self.tag],
                                     budgetCharacters: 100_000_000, destination: .local)
        return slices.compactMap { s in Self.decode(s.body).map { (s.id, $0) } }
    }

    /// Accepted, verified, strictly decodable rules, newest first. If two active entries share a rule id the
    /// newer one wins.
    public func activeEntries() throws -> [(recordID: String, rule: Rule)] {
        var seen = Set<String>()
        return try readable().filter { seen.insert($0.rule.id).inserted }
    }

    public func activeRules() throws -> [Rule] { try activeEntries().map(\.rule) }

    public func health() throws -> RuleStoreHealth {
        let readableIDs = Set(try readable().map { $0.recordID.uppercased() })
        let accepted = mind.records.filter { $0.kind == .policy && $0.status == .accepted && $0.tags.contains(Self.tag) }
        return RuleStoreHealth(untrustedEntryCount: accepted.filter { !readableIDs.contains($0.id.uppercased()) }.count)
    }

    /// The book to decide with. If any standing-rule entry is unverifiable it asks for everything.
    public func ruleBook(onboardedProjects: Set<String>) throws -> RuleBook {
        RuleBook(rules: try activeRules(), onboardedProjects: onboardedProjects,
                 hasUnverifiedRules: try health().untrustedEntryCount > 0)
    }
}
