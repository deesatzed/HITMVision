import Foundation
import HITMCore

extension SampleTask {
    /// A real card from a LiveSlice run, shaped for the existing panels. `isSample` is false, so no panel labels it as invented.
    init(card: ReviewCard) {
        let files = card.changedPaths.joined(separator: ", ")
        let planLines = card.steps.map { "\($0.text) [\($0.effectiveClass.rawValue)]" }
        let diff = card.diff.unicodeScalars.count > 3500
            ? String(String.UnicodeScalarView(card.diff.unicodeScalars.prefix(3500))) + "\n[diff shortened here; `LiveSlice show` has more]"
            : card.diff
        self.init(
            id: card.id, title: card.title,
            summary: "\(card.changedPaths.count) file(s): \(files)  (+\(card.addedLines) -\(card.removedLines))",
            role: "Implementer", action: card.overallClass, confidence: 1,
            plain: "The agent changed \(card.changedPaths.count) file(s) on its own branch. Nothing is merged into main either way.",
            reversible: true,
            evidence: card.reasons,
            ruleNotes: card.reasons,
            detail: diff + (card.diffTruncated ? "\n[diff truncated when the card was made]" : ""),
            proof: ["Real diff recorded at run time: +\(card.addedLines) -\(card.removedLines) in \(files).",
                    "Branch: \(card.branch ?? "none")."] + planLines.prefix(8).map { "Plan: \($0)" },
            isSample: false,
            liveGate: LiveGateInfo(needsHuman: card.needsHuman, reasons: card.reasons, gateFailed: card.gateFailed, branch: card.branch))
    }
}
