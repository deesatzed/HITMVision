import Foundation

public enum MindKind: String, Codable, CaseIterable, Sendable { case context, memory, prompt, policy }

public enum MindStatus: String, Codable, Sendable {
    case quarantined, accepted, rejected, expired, corrected, superseded
}

/// Errors never carry file contents.
public enum MindError: Error, Equatable, Sendable {
    case invalidEntry
    case unknownEntry
    case illegalTransition
    case integrityFailure
    case ioFailure(String)
}

/// Child file content. Immutable once written; status is NOT stored here (it lives only in the index).
public struct MindEntry: Codable, Equatable, Sendable {
    public let id: String
    public let kind: MindKind
    public let title: String
    public let body: String
    public let tags: [String]
    public let author: String
    public let createdRevision: Int
    public let evidence: [String]
    public let sensitive: Bool
    public let parentID: String?
    public let supersedes: String?
    /// Agent role this entry is meant for; nil = all roles.
    public let role: String?
}

/// Index record (one per entry in mind.json). `sha256` is the hex digest of the child file bytes.
public struct MindRecord: Codable, Equatable, Sendable {
    public let id: String
    public let kind: MindKind
    public internal(set) var status: MindStatus
    public let author: String
    public let sensitive: Bool
    public let createdRevision: Int
    public let supersedes: String?
    public let parentID: String?
    public let role: String?
    public let tags: [String]
    public let sha256: String
}

public enum AuditFinding: Equatable, Sendable {
    /// Child file missing or its hash differs from the index.
    case untrusted(String)
    /// File name in entries/ that the index does not reference.
    case orphan(String)
    /// The index status disagrees with the status implied by the latest log event for this id.
    /// (Also what a transition whose log append failed after the index write looks like.)
    case statusMismatch(String)
    /// The index has a record but the log has no propose event for it.
    case noLogEvent(String)
}

/// Proof that a kind of entry was approved: by a human, or by the automatic gate where policy allows.
/// Only `MindPolicy.approve` creates one outside this module.
public struct Approval: Sendable, Equatable {
    public let kind: MindKind
    /// The one entry this approval is for; it cannot accept any other.
    public let entryID: String
    /// "human:<name>" or "auto-gate".
    public let approver: String
    public let isHuman: Bool
    init(kind: MindKind, entryID: String, approver: String, isHuman: Bool) {
        self.kind = kind; self.entryID = entryID; self.approver = approver; self.isHuman = isHuman
    }
}

public enum MindDestination: Equatable, Sendable { case local, hostedModel }

public struct MindSlice: Equatable, Sendable {
    public let id: String
    public let kind: MindKind
    public let title: String
    public let body: String
    public let tags: [String]
}

/// Pure decision: does adding this kind of entry need a human?
public enum MindPolicy {
    public static func needsHuman(kind: MindKind, profile: RiskProfile,
                                  gate: Result<GateResponse, GateError>?) -> Bool {
        if kind == .policy { return true }
        if profile.isSensitive { return true }   // includes unsure
        let gateWantsHuman: Bool
        switch gate {
        case .none, .some(.failure): gateWantsHuman = true
        case .some(.success(let r)): gateWantsHuman = r.needsHuman || r.route != .proceed
        }
        if kind == .prompt {
            // Decide strictness through FloorGate.evaluate, never by reading profile fields.
            if case .humanRequired = FloorGate.evaluate(.editDomainLogic, profile: profile) { return true }
        }
        return gateWantsHuman
    }

    /// nil when a human is required and none (non-blank) was given.
    public static func approve(kind: MindKind, entryID: String, profile: RiskProfile,
                               gate: Result<GateResponse, GateError>?, human: String?) -> Approval? {
        let name = MindStore.singleLine(human ?? "", cap: 80)
        if !name.isEmpty { return Approval(kind: kind, entryID: entryID, approver: "human:\(name)", isHuman: true) }
        if needsHuman(kind: kind, profile: profile, gate: gate) { return nil }
        return Approval(kind: kind, entryID: entryID, approver: "auto-gate", isHuman: false)
    }
}
