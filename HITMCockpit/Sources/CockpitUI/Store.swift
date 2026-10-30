import Foundation
import HITMCore
import SwiftUI

public enum ProfileChoice: String, CaseIterable, Identifiable {
    case light = "Light", strict = "Strict", unsure = "Unsure"
    public var id: String { rawValue }
    public var profile: RiskProfile {
        switch self {
        case .light: return .light
        case .strict: return .strict
        case .unsure: return RiskProfile(name: "unsure", extraHumanRequired: [], unsure: true)
        }
    }
    public var blurb: String {
        switch self {
        case .light: return "Toy or throwaway project: only the always-ask list interrupts you."
        case .strict: return "Safety-sensitive project: core-logic and safety-check edits also reach you."
        case .unsure: return "Profile not confirmed: treated as strict."
        }
    }
}

/// What the gate says for one task under the current profile (floor from HITMCore, smart layer is a sample stand-in).
public struct Gate {
    public let needsHuman: Bool
    public let fromFloor: Bool
    public enum Kind: Equatable { case floorUniversal, floorProfile, agentConfidence, quiet }
    public let kind: Kind            // set once in CockpitStore.gate(for:); nothing else infers it from text
    public let reason: String        // technical reason, shown in the Rules layer
    public let tag: String           // short plain label on the card
    public let plainReason: String   // plain-English why it reached you
    public let icon: String          // SF Symbol so urgency never rests on color alone
}

/// Where an intent came from. Only `.typed` is produced today; `.voice` is the seam for a later voice input (no speech code exists).
public enum IntentSource: String { case typed, voice }

public enum Resolution { case passed, modified(String), rejected }

public struct AgentLine: Identifiable {
    public let id: String            // role
    public let text: String
    public let state: State
    public enum State { case working, waiting, idle }
}

@MainActor
public final class CockpitStore: ObservableObject {
    public init() {}

    @Published public var choice: ProfileChoice = .light
    @Published public private(set) var resolutions: [String: Resolution] = [:]
    @Published public private(set) var log = EventLog()
    @Published public private(set) var threshold = sampleConfidenceThreshold
    @Published public private(set) var lastIntent: String?
    @Published public private(set) var requests: [String] = []
    @Published public private(set) var smartPasses = 0
    @Published public private(set) var offerHandled = false
    /// The decision shown in the detail card. nil means "the first waiting item".
    @Published public private(set) var focusedID: String?

    public func gate(for task: SampleTask) -> Gate {
        let floor = FloorGate.evaluate(task.action, profile: choice.profile)
        let smart = task.confidence < threshold
        let needs = FloorGate.needsHuman(floor: floor, smartNeedsHuman: smart)
        if case .humanRequired(let reason) = floor {
            let universal = reason.hasPrefix("Universal")
            let plain: String
            switch task.action {
            case .irreversible: plain = "This can't be undone, so it always comes to you."
            case .deploy: plain = "This publishes your work somewhere, so it always comes to you."
            case .externalSend: plain = "This sends data off this machine, so it always comes to you."
            case .editDomainLogic: plain = "Your project settings ask you before core logic changes."
            case .editSafetyCheck: plain = "Your project settings ask you before a safety check is weakened."
            case .routine: plain = "Your project settings ask you about this."
            }
            return Gate(needsHuman: true, fromFloor: true, kind: universal ? .floorUniversal : .floorProfile, reason: reason,
                        tag: universal ? "ALWAYS ASKS" : "PROJECT RULE", plainReason: plain,
                        icon: universal ? "exclamationmark.octagon.fill" : "lock.shield.fill")
        }
        if smart {
            return Gate(needsHuman: needs, fromFloor: false, kind: .agentConfidence,
                        reason: String(format: "Gate: agent confidence %.2f is under %.2f (sample threshold)", task.confidence, threshold),
                        tag: "AGENT UNSURE",
                        plainReason: String(format: "The agent is only %.0f%% sure, so it's asking.", task.confidence * 100),
                        icon: "questionmark.circle.fill")
        }
        return Gate(needsHuman: false, fromFloor: false, kind: .quiet, reason: "Within profile; proceeding quietly",
                    tag: "QUIET", plainReason: "Within your project's rules.", icon: "checkmark.circle")
    }

    /// Everything waiting for the human, floor-rule items first, otherwise in task order.
    public var waiting: [SampleTask] {
        let pending = sampleTasks.enumerated().filter { gate(for: $0.element).needsHuman && resolutions[$0.element.id] == nil }
        return pending.sorted { a, b in
            let fa = gate(for: a.element).fromFloor, fb = gate(for: b.element).fromFloor
            return fa != fb ? fa : a.offset < b.offset
        }.map { $0.element }
    }
    public var quiet: [SampleTask] { sampleTasks.filter { !gate(for: $0).needsHuman } }
    public var decided: [SampleTask] { sampleTasks.filter { resolutions[$0.id] != nil } }
    public var interruptionCount: Int { sampleTasks.filter { gate(for: $0).needsHuman }.count }

    /// One line per agent role. PROTOTYPE SAMPLE ACTIVITY derived from the sample tasks.
    public var agentLines: [AgentLine] {
        ["Planner", "Implementer", "Reviewer"].map { role in
            if role == "Planner", let i = lastIntent {
                let blocked = waiting.filter { $0.role == role }.count
                return AgentLine(id: role, text: "Planning: \(i)" + (blocked > 0 ? " (+\(blocked) waiting for you)" : ""), state: .working)
            }
            if let t = waiting.first(where: { $0.role == role }) {
                return AgentLine(id: role, text: "Waiting for you: \(t.title)", state: .waiting)
            }
            if let t = quiet.first(where: { $0.role == role && resolutions[$0.id] == nil }) {
                return AgentLine(id: role, text: "Working: \(t.title)", state: .working)
            }
            return AgentLine(id: role, text: "Idle", state: .idle)
        }
    }

    /// The focused task if it is still waiting, otherwise the first waiting task.
    public var focusedTask: SampleTask? {
        if let id = focusedID, let t = waiting.first(where: { $0.id == id }) { return t }
        return waiting.first
    }

    /// Sticks only if the id is currently waiting.
    public func focus(_ id: String) {
        guard waiting.contains(where: { $0.id == id }) else { return }
        focusedID = id
    }

    public var showOffer: Bool { smartPasses >= 2 && !offerHandled }

    public func resolve(_ task: SampleTask, _ r: Resolution) {
        let g = gate(for: task)
        let before = waiting.map { $0.id }
        resolutions[task.id] = r
        if focusedID == task.id { advanceFocus(from: task.id, in: before) }
        normaliseFocus()
        switch r {
        case .passed:
            log.append(kind: "pass", payload: "\(task.id) \(task.title)", author: "human")
            if !g.fromFloor { smartPasses += 1 }
        case .modified(let note): log.append(kind: "modify", payload: "\(task.id) \(task.title): \(note)", author: "human")
        case .rejected: log.append(kind: "reject", payload: "\(task.id) \(task.title)", author: "human")
        }
    }

    public func submitIntent(_ text: String, source: IntentSource = .typed) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lastIntent = t
        requests.append(t)
        log.append(kind: "intent", payload: "\(source.rawValue): \(t)", author: "human")
    }

    /// Floor rules are never offered for relaxing; only the agent-unsure threshold is.
    public func answerOffer(accept: Bool) {
        offerHandled = true
        if accept {
            threshold = relaxedConfidenceThreshold
            log.append(kind: "policy", payload: String(format: "accepted: stop asking about routine work at confidence >= %.2f", threshold), author: "human")
        } else {
            log.append(kind: "policy", payload: "declined: keep asking at the current confidence threshold", author: "human")
        }
    }

    public func setProfile(_ c: ProfileChoice) {
        guard c != choice else { return }
        let before = waiting.map { $0.id }
        choice = c
        if let id = focusedID, !waiting.contains(where: { $0.id == id }) { advanceFocus(from: id, in: before) }
        normaliseFocus()
        log.append(kind: "profile", payload: "profile set to \(c.rawValue)", author: "human")
    }

    public func reset() {
        resolutions = [:]
        log = EventLog()
        choice = .light
        threshold = sampleConfidenceThreshold
        lastIntent = nil
        requests = []
        smartPasses = 0
        offerHandled = false
        focusedID = nil
    }

    /// After resolve / setProfile, focusedID equals the effective focused id (nil only when nothing is waiting),
    /// so a stale id cannot come back later. Untouched default (nil) stays nil until one of those calls.
    private func normaliseFocus() { focusedID = focusedTask?.id }

    /// Focus moves to the next waiting item after `id` in the old queue order, else the first waiting item.
    private func advanceFocus(from id: String, in before: [String]) {
        let now = waiting.map { $0.id }
        let after = before.drop(while: { $0 != id }).dropFirst()
        focusedID = after.first(where: { now.contains($0) }) ?? now.first
    }

    public func label(_ r: Resolution) -> String {
        switch r {
        case .passed: return "Passed"
        case .modified: return "Modified"
        case .rejected: return "Rejected"
        }
    }
}
