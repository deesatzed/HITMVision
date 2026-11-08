import Foundation
import HITMCore

/// The five answers (plus Evidence) for one waiting decision, built only from what the system has:
/// the task, the gate result, the profile and the current queue. Pure value; no UI, no I/O.
/// Anything the system cannot fill yet is listed in `how.unavailable`, never invented.
public struct DecisionBrief {
    public struct What { public let title: String, plain: String, role: String, taskID: String, summary: String, detail: String, reversible: Bool }

    public enum Source { case floorUniversal, floorProfile, agentConfidence, gateAsked }
    public struct Why { public let source: Source, plainReason: String, technicalReason: String }

    public struct Scope {
        public let text: String
        public let broaderRulesLater: Bool   // marker only; no control exists yet
    }

    public struct Unavailable { public let name: String, status: String }
    public struct How {
        public let method: String
        public let inputs: [String]
        public let unavailable: [Unavailable]
    }

    public struct Next {
        public let pass: String, modify: String, reject: String
        public let unblocks: [SampleTask]    // OTHER waiting tasks with the same role
    }

    public enum Evidence: Equatable {
        case proof([String])
        case noProofAttached
    }

    public let what: What
    public let why: Why
    public let scope: Scope
    public let how: How
    public let next: Next
    public let evidence: Evidence
    /// True when proof / summary / detail come from invented sample tasks; the UI must label them.
    public let contentIsSample: Bool

    public static let notAvailableInSample = "Not available in sample mode"

    /// Returns nil for a quiet task: no human decision, so nothing to brief.
    public init?(task: SampleTask, gate: Gate, profile: ProfileChoice, waiting: [SampleTask]) {
        guard gate.needsHuman else { return nil }

        what = What(title: task.title, plain: task.plain, role: task.role, taskID: task.id,
                    summary: task.summary, detail: task.detail, reversible: task.reversible)
        contentIsSample = task.isSample

        let source: Source
        switch gate.kind {
        case .floorUniversal: source = .floorUniversal
        case .floorProfile: source = .floorProfile
        case .agentConfidence, .quiet: source = .agentConfidence
        case .gateAsked: source = .gateAsked
        }
        why = Why(source: source, plainReason: gate.plainReason, technicalReason: gate.reason)

        scope = Scope(text: "This one action only.", broaderRulesLater: true)

        if let live = task.liveGate {
            // Real run: everything shown was recorded when the agent ran.
            how = How(
                method: "Fixed floor rules first, then the gate model; both answers were recorded when the agent ran.",
                inputs: ["Action class: \(task.action.rawValue)"] + live.reasons.map { "Recorded: \($0)" },
                unavailable: ["History preview"].map { Unavailable(name: $0, status: "Not built yet") })
            next = Next(
                pass: "Pass: the change is committed on its own branch (\(live.branch ?? "none")). Nothing is merged into main.",
                modify: "Modify: not available for live cards yet.",
                reject: "Reject: the branch and its working copy are removed. Nothing else changes.",
                unblocks: waiting.filter { $0.role == task.role && $0.id != task.id })
        } else {
        how = How(
            method: gate.fromFloor ? "Fixed floor rule" : "Sample confidence threshold (stand-in for the gate model)",
            inputs: ["Action class: \(task.action.rawValue)", "Profile: \(profile.rawValue)"]
                + (source == .agentConfidence ? [String(format: "Agent confidence: %.2f", task.confidence)] : []),
            unavailable: ["Gate-model reasoning", "Inputs sent to a model", "History preview"]
                .map { Unavailable(name: $0, status: DecisionBrief.notAvailableInSample) })

        next = Next(
            pass: "Pass: the agent goes ahead with this one action.",
            modify: "Modify: you add a note and the agent revises before acting.",
            reject: "Reject: the agent does not do this action.",
            unblocks: waiting.filter { $0.role == task.role && $0.id != task.id })
        }

        evidence = task.proof.isEmpty ? .noProofAttached : .proof(task.proof)
    }
}
