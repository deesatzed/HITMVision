import Foundation
import HITMCore

// Usage: PlannerLiveCheck <planner-model-id> <gate-model-id> "<intent text>"
// Never prints the key, request bodies or raw responses.

let args = CommandLine.arguments
guard args.count == 4, !args[1].isEmpty, !args[2].isEmpty, !args[3].isEmpty else {
    FileHandle.standardError.write(Data("usage: PlannerLiveCheck <planner-model-id> <gate-model-id> \"<intent text>\"\n".utf8))
    exit(64)
}
let plannerModel = args[1], gateModel = args[2], intent = args[3]
guard let transport = OpenRouterGateClient.transportFromEnvironment(model: plannerModel),
      let gateClient = OpenRouterGateClient.fromEnvironment(model: gateModel) else {
    FileHandle.standardError.write(Data("OPENROUTER_API_KEY is missing or empty in the environment.\n".utf8))
    exit(2)
}

print("INTENT TEXT IS SENT TO THE PLANNER MODEL AND A TITLE-ONLY SUMMARY TO THE GATE MODEL")
print("planner model requested: \(plannerModel) | gate model requested: \(gateModel)")

func opt<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "-" }
func show(_ label: String, _ r: CallRecord) {
    print("\(label) record: http=\(opt(r.httpStatus)) used=\(opt(r.usedModel)) latencyMs=\(r.latencyMs) tokens=\(opt(r.promptTokens))/\(opt(r.completionTokens)) costUSD=\(opt(r.costUSD)) outcome=\(r.outcome)")
}

let profile = RiskProfile.light
let (result, plannerRecord) = await PlannerAgent(transport: transport).propose(intent: intent, profile: profile, profileSensitive: false)
if let plannerRecord { show("PLANNER", plannerRecord) }
guard case .success(let proposal) = result else {
    print("PLANNER FAILED: \(result)")
    exit(1)
}

print("PROPOSAL: \(proposal.title)")
for (i, s) in proposal.effectiveSteps.enumerated() {
    print("  \(i + 1). \(s.text)  [\(s.claimedClass.rawValue) -> \(s.effectiveClass.rawValue)]")
}
print("  risks: \(proposal.risks.isEmpty ? "none" : proposal.risks.joined(separator: " | "))")
print("  questions: \(proposal.questions.isEmpty ? "none" : proposal.questions.joined(separator: " | "))")
print("  overall class: \(proposal.overallClass.rawValue)")

let gateRequest = ProposalGate.gateRequest(for: proposal, profile: profile, profileSensitive: false)
let (gateResult, gateRecord) = await gateClient.assess(gateRequest)
let decision = ProposalGate.decide(proposal: proposal, profile: profile, gate: gateResult)
print("FINAL DECISION: needsHuman=\(decision.needsHuman) detailLevel=\(decision.detailLevel) gateFailed=\(decision.gateFailed)")
for r in decision.reasons { print("  reason: \(r)") }
show("GATE", gateRecord)
