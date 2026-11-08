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
    public enum Kind: Equatable { case floorUniversal, floorProfile, agentConfidence, gateAsked, quiet }
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

    // MARK: live cards (real runs written to <repo>/.hitm/inbox by LiveSlice)
    /// Where live cards come from. nil means the prototype's sample tasks are shown.
    struct LiveSource {
        let inbox: CardInbox
        let reviewer: String
        let apply: ((ReviewCard, Bool) throws -> Void)?
    }
    private var liveSource: LiveSource?
    @Published public private(set) var liveTasks: [SampleTask] = []
    @Published public private(set) var liveError: String?
    @Published public private(set) var failedRuns = 0
    public var isLive: Bool { liveSource != nil }
    /// Sample tasks, or the real cards once live mode is on.
    public var tasks: [SampleTask] { isLive ? liveTasks : sampleTasks }

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
        if let live = task.liveGate { return Self.liveGate(for: task, live) }
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
        let pending = tasks.enumerated().filter { gate(for: $0.element).needsHuman && resolutions[$0.element.id] == nil }
        return pending.sorted { a, b in
            let fa = gate(for: a.element).fromFloor, fb = gate(for: b.element).fromFloor
            return fa != fb ? fa : a.offset < b.offset
        }.map { $0.element }
    }
    public var quiet: [SampleTask] { tasks.filter { !gate(for: $0).needsHuman } }
    public var decided: [SampleTask] { tasks.filter { resolutions[$0.id] != nil } }
    public var interruptionCount: Int { tasks.filter { gate(for: $0).needsHuman }.count }

    /// One line per agent role. PROTOTYPE SAMPLE ACTIVITY derived from the sample tasks.
    public var agentLines: [AgentLine] {
        ["Planner", "Implementer", "Reviewer"].map { role in
            if !isLive, role == "Planner", let i = lastIntent {
                let blocked = waiting.filter { $0.role == role }.count
                return AgentLine(id: role, text: "Planning: \(i)" + (blocked > 0 ? " (+\(blocked) waiting for you)" : ""), state: .working)
            }
            if let t = waiting.first(where: { $0.role == role }) {
                return AgentLine(id: role, text: "Waiting for you: \(t.title)", state: .waiting)
            }
            if !isLive, let t = quiet.first(where: { $0.role == role && resolutions[$0.id] == nil }) {
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

    public var showOffer: Bool { !isLive && smartPasses >= 2 && !offerHandled }

    public func resolve(_ task: SampleTask, _ r: Resolution) {
        if liveSource != nil, task.liveGate != nil { resolveLive(task, r); return }
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
        if isLive { refreshLive(); return }
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

// MARK: - live cards
extension CockpitStore {
    /// Switch to real cards from `<repo>/.hitm/inbox`. `apply` (macOS only) commits or discards the card's branch after
    /// the decision is recorded; where it is nil the decision is only recorded and `LiveSlice sync` applies it later.
    public func enableLive(repo: URL, reviewer: String, apply: ((ReviewCard, Bool) throws -> Void)?) {
        let name = reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        liveSource = LiveSource(inbox: CardInbox(directory: repo.appendingPathComponent(".hitm/inbox")),
                                reviewer: name.isEmpty ? "cockpit-user" : name, apply: apply)
        refreshLive()
    }

    /// Reads the inbox again. Decided cards come back as decided; failed runs are counted, not listed as work.
    public func refreshLive() {
        guard let src = liveSource else { return }
        let cards = src.inbox.list()
        var res: [String: Resolution] = [:]
        for c in cards {
            if c.status == .passed { res[c.id] = .passed } else if c.status == .rejected { res[c.id] = .rejected }
        }
        let shown = cards.filter { $0.status != .failed }
        failedRuns = cards.count - shown.count
        // The queue shows oldest first, so a long-waiting card is not buried by new ones.
        liveTasks = shown.reversed().map { SampleTask(card: $0) }
        resolutions = res
        normaliseLiveFocus()
    }

    /// Polls while live; ends when the task is cancelled.
    public func pollLive() async {
        while !Task.isCancelled {
            refreshLive()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func resolveLive(_ task: SampleTask, _ r: Resolution) {
        guard let src = liveSource else { return }
        let pass: Bool
        switch r {
        case .passed: pass = true
        case .rejected: pass = false
        case .modified:
            liveError = "Modify isn't available for live cards yet. Use Pass or Reject."
            return
        }
        liveError = nil
        let card: ReviewCard
        do { card = try src.inbox.decide(task.id, to: pass ? .passed : .rejected, by: src.reviewer) }
        catch {
            liveError = "Could not record your decision (\(error)). Nothing changed."
            refreshLive(); return
        }
        log.append(kind: pass ? "pass" : "reject", payload: "\(task.id) \(task.title)", author: "human")
        if let apply = src.apply {
            do { try apply(card, pass) }
            catch { liveError = "Your decision is recorded, but the branch was not updated (\(error)). Run LiveSlice sync." }
        } else {
            liveError = "Decision recorded. Run LiveSlice sync on the Mac to \(pass ? "commit" : "remove") the branch."
        }
        refreshLive()
    }

    private func normaliseLiveFocus() {
        if let id = focusedID, !waiting.contains(where: { $0.id == id }) { focusedID = waiting.first?.id }
    }

    static func liveGate(for task: SampleTask, _ live: LiveGateInfo) -> Gate {
        let floorLine = live.reasons.first { $0.hasPrefix("Universal floor") || $0.hasPrefix("Profile '") }
        let other = live.reasons.first { $0 != floorLine && !$0.hasPrefix("Gate unavailable") } ?? ""
        let technical = live.reasons.joined(separator: " | ")
        guard live.needsHuman else {
            return Gate(needsHuman: false, fromFloor: false, kind: .quiet, reason: technical.isEmpty ? "Within profile; proceeded quietly" : technical,
                        tag: "QUIET", plainReason: "Within your project's rules.", icon: "checkmark.circle")
        }
        if let f = floorLine {
            let universal = f.hasPrefix("Universal floor")
            let plain: String
            switch task.action {
            case .irreversible: plain = "This can't be undone, so it always comes to you."
            case .deploy: plain = "This publishes your work somewhere, so it always comes to you."
            case .externalSend: plain = "This sends data off this machine, so it always comes to you."
            case .editDomainLogic: plain = "Your project settings ask you before core logic changes."
            case .editSafetyCheck: plain = "Your project settings ask you before a safety check is weakened."
            case .routine: plain = "Your project settings ask you about this."
            }
            return Gate(needsHuman: true, fromFloor: true, kind: universal ? .floorUniversal : .floorProfile, reason: technical,
                        tag: universal ? "ALWAYS ASKS" : "PROJECT RULE", plainReason: plain + (other.isEmpty ? "" : " Gate note: \(other)"),
                        icon: universal ? "exclamationmark.octagon.fill" : "lock.shield.fill")
        }
        let plain = live.gateFailed ? "The safety-check model could not answer, so it's asking you."
                                    : "The safety-check model wanted you to look. \(other)"
        return Gate(needsHuman: true, fromFloor: false, kind: .gateAsked, reason: technical,
                    tag: "GATE ASKED", plainReason: plain, icon: "questionmark.circle.fill")
    }
}
