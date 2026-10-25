import Foundation
import HITMCore

// Usage: GateLiveCheck <model-id>
// Sends SIX INVENTED sample requests to the gate. Prints one summary line per call.
// Never prints the key, request body or raw response.

let args = CommandLine.arguments
guard args.count == 2, !args[1].isEmpty else {
    FileHandle.standardError.write(Data("usage: GateLiveCheck <model-id>\n".utf8))
    exit(64)
}
let model = args[1]
guard let client = OpenRouterGateClient.fromEnvironment(model: model) else {
    FileHandle.standardError.write(Data("OPENROUTER_API_KEY is missing or empty in the environment.\n".utf8))
    exit(2)
}

struct Sample {
    let id: Int
    let request: GateRequest
    let profile: RiskProfile
    let sensitive: Bool
}

func sample(_ id: Int, _ action: ActionClass, profile: RiskProfile = .light, paths: [String],
            size: Int, conf: Double, summary: String, sensitive: Bool = false) -> Sample {
    Sample(id: id, request: GateRequest.make(actionClass: action, profileName: profile.name, filePaths: paths,
                                             changeSize: size, agentConfidence: conf, overrideHistory: "none",
                                             summary: summary, profileSensitive: sensitive),
           profile: profile, sensitive: sensitive)
}

let samples = [
    sample(1, .routine, paths: ["README.md"], size: 2, conf: 0.96, summary: "INVENTED: fix a typo in the readme"),
    sample(2, .routine, paths: ["Sources/Session.swift", "Sources/Cache.swift"], size: 40, conf: 0.62,
           summary: "INVENTED: refactor session cache invalidation"),
    sample(3, .deploy, paths: ["deploy.yml"], size: 5, conf: 0.90, summary: "INVENTED: deploy build to staging"),
    sample(4, .editSafetyCheck, profile: .strict, paths: ["Sources/Guard.swift"], size: 8, conf: 0.74,
           summary: "INVENTED: relax a bounds check in a guard"),
    sample(5, .irreversible, paths: ["data/archive"], size: 1, conf: 0.97, summary: "INVENTED: delete an old archive folder"),
    sample(6, .editDomainLogic, paths: ["Sources/Domain.swift"], size: 12, conf: 0.80,
           summary: "INVENTED: this summary must NOT be sent", sensitive: true),
]

print("INVENTED SAMPLE DATA  (model requested: \(model))")

var failures = 0, finalHuman = 0, totalLatency = 0
var totalCost = 0.0, anyCost = false

for s in samples {
    let floor = FloorGate.evaluate(s.request.actionClass, profile: s.profile)
    let (result, rec) = await client.assess(s.request)
    let decision = GateDecision.combine(floor: floor, gate: result)
    let floorText: String
    if case .humanRequired = floor { floorText = "human required" } else { floorText = "none" }
    let gateText: String
    switch result {
    case .success(let g):
        gateText = "route=\(g.route.rawValue) needsHuman=\(g.needsHuman) conf=\(g.confidence) reason=\"\(g.reason)\""
    case .failure(let e):
        failures += 1
        gateText = "FAILED(\(e))"
    }
    if decision.needsHuman { finalHuman += 1 }
    totalLatency += rec.latencyMs
    if let c = rec.costUSD { totalCost += c; anyCost = true }
    func opt<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "-" }
    print("#\(s.id) \(s.request.actionClass.rawValue)\(s.sensitive ? " [sensitive]" : "") | floor: \(floorText) | gate: \(gateText) | FINAL needsHuman=\(decision.needsHuman) | http=\(opt(rec.httpStatus)) used=\(opt(rec.usedModel)) latencyMs=\(rec.latencyMs) tokens=\(opt(rec.promptTokens))/\(opt(rec.completionTokens)) costUSD=\(opt(rec.costUSD)) outcome=\(rec.outcome)")
}

print("AGGREGATE: calls=\(samples.count) failures=\(failures) finalNeedsHuman=\(finalHuman) totalLatencyMs=\(totalLatency) totalCostUSD=\(anyCost ? String(totalCost) : "n/a")")
