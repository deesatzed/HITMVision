import Foundation

public enum PlannerError: Error, Equatable, Sendable {
    case blockedBySensitiveProfile, unavailable, malformed, outOfRange
}

public struct ProposalStep: Codable, Equatable, Sendable {
    public let text: String
    public let claimedClass: ActionClass
    public init(text: String, claimedClass: ActionClass) { self.text = text; self.claimedClass = claimedClass }
}

public struct EffectiveStep: Equatable, Sendable {
    public let text: String
    public let claimedClass: ActionClass
    public let effectiveClass: ActionClass
}

public struct Proposal: Codable, Equatable, Sendable {
    public let title: String
    public let steps: [ProposalStep]
    public let risks: [String]
    public let questions: [String]

    public init(title: String, steps: [ProposalStep], risks: [String], questions: [String]) {
        self.title = title; self.steps = steps; self.risks = risks; self.questions = questions
    }

    /// Strict decode. Bad JSON, wrong types, missing fields or an unknown class => .malformed.
    /// Counts out of bounds or empty title/step after sanitizing => .outOfRange.
    public static func decodeStrict(_ data: Data) -> Result<Proposal, PlannerError> {
        guard let raw = try? JSONDecoder().decode(Proposal.self, from: data) else { return .failure(.malformed) }
        guard (1...8).contains(raw.steps.count), raw.risks.count <= 5, raw.questions.count <= 5
        else { return .failure(.outOfRange) }
        let title = GateResponse.sanitize(raw.title)
        let steps = raw.steps.map { ProposalStep(text: GateResponse.sanitize($0.text), claimedClass: $0.claimedClass) }
        guard !title.isEmpty, !steps.contains(where: { $0.text.isEmpty }) else { return .failure(.outOfRange) }
        return .success(Proposal(title: title, steps: steps,
                                 risks: raw.risks.map(GateResponse.sanitize),
                                 questions: raw.questions.map(GateResponse.sanitize)))
    }

    /// Each step's FINAL class: the higher severity of the model's claim and the rule-based minimum.
    /// The model can raise a class but never lower it.
    public var effectiveSteps: [EffectiveStep] {
        steps.map { s in
            let minimum = ActionClassifier.minimumClass(forStepText: s.text)
            let eff = ActionClassifier.severity(minimum) > ActionClassifier.severity(s.claimedClass) ? minimum : s.claimedClass
            return EffectiveStep(text: s.text, claimedClass: s.claimedClass, effectiveClass: eff)
        }
    }

    public var overallClass: ActionClass {
        effectiveSteps.map(\.effectiveClass).max { ActionClassifier.severity($0) < ActionClassifier.severity($1) } ?? .routine
    }
}

/// Pure, conservative, keyword-based lower bound on a step's class (case-insensitive substring match).
public enum ActionClassifier {
    public static func severity(_ c: ActionClass) -> Int {
        switch c {
        case .routine: return 0
        case .editDomainLogic: return 1
        case .editSafetyCheck: return 2
        case .externalSend: return 3
        case .deploy: return 4
        case .irreversible: return 5
        }
    }

    // Rules are checked from most to least severe; the first rule with a matching keyword wins.
    private static let rules: [(ActionClass, [String])] = [
        // irreversible: data or history that cannot be recovered
        (.irreversible, ["delete", "drop", "remove permanently", "destroy", "wipe", "truncate", "force push", "overwrite"]),
        // deploy: changes what runs in a live environment
        (.deploy, ["deploy", "release", "publish", "ship to", "push to prod"]),
        // externalSend: data leaves the machine
        (.externalSend, ["upload", "send", "email", "post to", "webhook", "external service", "third-party", "telemetry"]),
        // editSafetyCheck: weakens or changes a protective check
        (.editSafetyCheck, ["safety", "assertion", "validation", "guard", "limit", "tolerance", "permission", "auth"]),
        // editDomainLogic: changes what the software computes or decides
        (.editDomainLogic, ["business rule", "core logic", "calculation", "pricing", "algorithm"]),
    ]

    public static func minimumClass(forStepText text: String) -> ActionClass {
        let t = text.lowercased()
        for (cls, words) in rules where words.contains(where: { t.contains($0) }) { return cls }
        return .routine
    }
}
