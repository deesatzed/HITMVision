import Foundation
import HITMCore

// Usage: LiveSlice run    <repo> <planner-model> <implementer-model> <gate-model> "<intent>" [light|strict]
//        LiveSlice list   <repo>
//        LiveSlice show   <repo> <card-id>
//        LiveSlice decide <repo> <card-id> pass|reject <your-name>
// `run` SENDS THE REPO'S FILES to the planner/implementer models and a title-only summary to the gate model.
// Use it on a throwaway repo unless you have approved the destination. Never prints the key, a request or a raw response.

let args = CommandLine.arguments
func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: LiveSlice run <repo> <planner-model> <implementer-model> <gate-model> "<intent>" [light|strict]
               LiveSlice list <repo> | show <repo> <id> | decide <repo> <id> pass|reject <your-name>\n
        """.utf8))
    exit(64)
}
guard args.count >= 3 else { usage() }
let mode = args[1]
guard let ws = try? Workspace(repo: URL(fileURLWithPath: args[2])) else {
    FileHandle.standardError.write(Data("not a git repo root: \(args[2])\n".utf8)); exit(66)
}
let inbox = CardInbox(directory: ws.repo.appendingPathComponent(".hitm/inbox"))

func show(_ c: ReviewCard, full: Bool) {
    print("card \(c.id)  status=\(c.status.rawValue)  needsHuman=\(c.needsHuman)  class=\(c.overallClass.rawValue)  detail=\(c.detailLevel)  gateFailed=\(c.gateFailed)")
    print("  title: \(c.title)")
    for (i, s) in c.steps.enumerated() { print("  \(i + 1). \(s.text)  [\(s.claimedClass.rawValue) -> \(s.effectiveClass.rawValue)]") }
    print("  files: \(c.changedPaths.joined(separator: ", "))  (+\(c.addedLines) -\(c.removedLines))  branch: \(c.branch ?? "-")")
    for r in c.reasons { print("  reason: \(r)") }
    if let by = c.decidedBy { print("  decided by \(by)") }
    if full { print(c.diff); if c.diffTruncated { print("[diff truncated]") } }
}

switch mode {
case "run":
    guard args.count >= 7, !args[3].isEmpty, !args[4].isEmpty, !args[5].isEmpty, !args[6].isEmpty else { usage() }
    let profile: RiskProfile = (args.count > 7 && args[7] == "strict") ? .strict : .light
    guard let deps = SliceDeps.openRouter(planner: args[3], implementer: args[4], gate: args[5]) else {
        FileHandle.standardError.write(Data("OPENROUTER_API_KEY is missing or empty in the environment.\n".utf8)); exit(2)
    }
    print("REPO FILES ARE SENT TO THE PLANNER/IMPLEMENTER MODELS. planner=\(args[3]) implementer=\(args[4]) gate=\(args[5]) profile=\(profile.name)")
    let card = await SliceRunner(workspace: ws, deps: deps, profile: profile).run(intent: args[6])
    show(card, full: true)
    let led = CallLedger(fileURL: ws.repo.appendingPathComponent(".hitm/runs/\(card.id).jsonl"))
    if let u = try? led.usage() { print("ledger: calls=\(u.calls) knownCostUSD=\(u.knownCostUSD) callsWithUnknownCost=\(u.callsWithUnknownCost) unresolved=\(u.unresolved.count)") }
    exit(card.status == .failed ? 1 : 0)
case "list":
    for c in inbox.list() { print("\(c.id)  \(c.status.rawValue)  needsHuman=\(c.needsHuman)  \(c.title)") }
case "show":
    guard args.count == 4, let c = try? inbox.load(args[3]) else { usage() }
    show(c, full: true)
case "decide":
    guard args.count == 6, args[4] == "pass" || args[4] == "reject" else { usage() }
    let dummy = SliceDeps(plan: { _, _ in (.failure(.unavailable), nil) }, implement: { _, _, _, _ in (.failure(.unavailable), nil) },
                          gate: { _ in (.failure(.unavailable), CallRecord(requestedModel: "-", usedModel: nil, httpStatus: nil, latencyMs: 0, promptTokens: nil, completionTokens: nil, costUSD: nil, outcome: "unused")) },
                          models: [:])
    do { show(try SliceRunner(workspace: ws, deps: dummy).resolve(cardID: args[3], pass: args[4] == "pass", by: args[5]), full: false) }
    catch { FileHandle.standardError.write(Data("could not decide: \(error)\n".utf8)); exit(1) }
default: usage()
}
