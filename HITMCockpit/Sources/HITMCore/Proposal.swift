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
        // The whole proposal is classified: steps, title, risks and questions.
        let texts = [title] + risks + questions
        let all = effectiveSteps.map(\.effectiveClass) + texts.map { ActionClassifier.minimumClass(forStepText: $0) }
        return all.max { ActionClassifier.severity($0) < ActionClassifier.severity($1) } ?? .routine
    }
}

/// Pure, conservative, keyword-based LOWER BOUND on an action's class. Text is normalized (NFKC,
/// lowercase, collapsed whitespace) and matched on WORD STARTS, never raw substrings.
///
/// ACCEPTED LIMITS: other natural languages, homoglyph letters (e.g. Cyrillic look-alikes) and novel
/// synonyms ("eliminate", "get rid of") are NOT caught. This is a floor that works alongside the
/// gate model and the human, not a complete detector.
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

    // irreversible: destroys data or history. Plain "remove" and plain "drop" are not enough;
    // "undelete" does not match because the stem must start a word.
    static let irreversibleTerms = ["delet", "deletion", "eras", "purg", "destroy", "wipe", "truncat", "nuke",
        "obliterat", "overwrit", "rm -rf", "force push", "git push --force", "reset --hard", "drop table",
        "drop database", "drop schema", "drop column", "drop collection", "remove permanently", "permanently remov"]
    // deploy: changes what runs live. "release notes" / "released lock" do not match: only "release to".
    static let deployTerms = ["deploy", "go live", "roll out", "rollout", "push to prod", "push to main",
        "ship to", "release to", "publish to", "publish the"]
    // externalSend: a sending verb plus an external target in the same text, or a clear external term.
    static let sendVerbs = ["upload", "send", "transmit", "post", "email", "mail", "sync", "share", "export",
        "forward", "exfiltrate", "curl"]
    static let sendTargets = ["external", "third-party", "third party", "vendor", "cloud", "remote", "partner",
        "webhook", "external service", "http:", "https:", "endpoint", "api"]
    static let sendStandalone = ["webhook", "exfiltrat", "third-party service", "third party service"]
    // editSafetyCheck: protective-check vocabulary, or a weakening verb near a check-like word.
    static let safetyTerms = ["assertion", "tolerance", "permission", "credential", "password", "authenticat",
        "authoriz", "safety check", "bounds check", "rate limit", "limit check", "threshold"]
    static let safetyWholeWords: Set<String> = ["guard", "guards"]
    static let weakeners = ["disable", "skip", "bypass", "relax", "loosen", "remove", "widen", "ignore"]
    static let checkWordStarts = ["check", "test", "assert", "validation", "threshold", "tolerance"]
    static let checkWholeWords: Set<String> = ["guard", "guards", "limit", "limits"]
    // editDomainLogic: changes what the software computes or decides.
    static let domainTerms = ["business rule", "core logic", "calculation", "pricing", "algorithm"]

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func tokens(_ norm: String) -> [String] {
        norm.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// `needle` occurs in `hay` at the start of a word.
    static func hasWordStart(_ hay: String, _ needle: String) -> Bool {
        var from = hay.startIndex
        while let r = hay.range(of: needle, range: from..<hay.endIndex) {
            if r.lowerBound == hay.startIndex { return true }
            let prev = hay[hay.index(before: r.lowerBound)]
            if !(prev.isLetter || prev.isNumber) { return true }
            from = hay.index(after: r.lowerBound)
        }
        return false
    }

    /// Catches split-up spellings ("del ete", "d e l e t e", "force-push"): joins up to 8 consecutive
    /// tokens starting at a token start. Stems match as a prefix of the join; phrases must equal it.
    static func squeezedHit(_ toks: [String], _ terms: [String]) -> Bool {
        for term in terms {
            let isPhrase = term.contains(" ")
            let sq = term.filter { $0.isLetter || $0.isNumber }
            for i in toks.indices {
                var joined = ""
                for j in i..<min(toks.count, i + 8) {
                    joined += toks[j]
                    if isPhrase ? joined == sq : joined.hasPrefix(sq) { return true }
                    if joined.count >= sq.count { break }
                }
            }
        }
        return false
    }

    static func hasAny(_ norm: String, _ terms: [String]) -> Bool { terms.contains { hasWordStart(norm, $0) } }

    public static func minimumClass(forStepText text: String) -> ActionClass {
        let norm = normalize(text)
        let toks = tokens(norm)
        if hasAny(norm, irreversibleTerms) || squeezedHit(toks, irreversibleTerms) { return .irreversible }
        if hasAny(norm, deployTerms) || squeezedHit(toks, deployTerms) { return .deploy }
        if hasAny(norm, sendStandalone) { return .externalSend }
        if hasAny(norm, sendVerbs) && hasAny(norm, sendTargets) { return .externalSend }
        if hasAny(norm, safetyTerms) || toks.contains(where: { safetyWholeWords.contains($0) }) { return .editSafetyCheck }
        if weakeningNearCheck(toks) { return .editSafetyCheck }
        if hasAny(norm, domainTerms) { return .editDomainLogic }
        return .routine
    }

    /// A weakening verb within 4 tokens of a check-like word.
    static func weakeningNearCheck(_ toks: [String]) -> Bool {
        for (i, t) in toks.enumerated() where weakeners.contains(where: { t.hasPrefix($0) }) {
            for j in max(0, i - 4)...min(toks.count - 1, i + 4) where j != i {
                let w = toks[j]
                if checkWholeWords.contains(w) || checkWordStarts.contains(where: { w.hasPrefix($0) }) { return true }
            }
        }
        return false
    }
}
