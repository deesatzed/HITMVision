import Foundation

#if os(macOS)
/// The three model roles, as functions so the flow can be tested without a network.
public struct SliceDeps: Sendable {
    public var plan: @Sendable (String, RiskProfile) async -> (Result<Proposal, PlannerError>, CallRecord?)
    public var implement: @Sendable (String, Proposal, [String: String], RiskProfile) async -> (Result<ChangeSet, ImplementerError>, CallRecord?)
    public var gate: @Sendable (GateRequest) async -> (Result<GateResponse, GateError>, CallRecord)
    public var models: [String: String]

    public init(plan: @escaping @Sendable (String, RiskProfile) async -> (Result<Proposal, PlannerError>, CallRecord?),
                implement: @escaping @Sendable (String, Proposal, [String: String], RiskProfile) async -> (Result<ChangeSet, ImplementerError>, CallRecord?),
                gate: @escaping @Sendable (GateRequest) async -> (Result<GateResponse, GateError>, CallRecord),
                models: [String: String]) {
        self.plan = plan; self.implement = implement; self.gate = gate; self.models = models
    }

    /// Real OpenRouter roles. nil when the key is missing.
    public static func openRouter(planner: String, implementer: String, gate: String) -> SliceDeps? {
        guard let pt = OpenRouterGateClient.transportFromEnvironment(model: planner),
              let it = OpenRouterGateClient.transportFromEnvironment(model: implementer),
              let g = OpenRouterGateClient.fromEnvironment(model: gate) else { return nil }
        let p = PlannerAgent(transport: pt), i = ImplementerAgent(transport: it)
        return SliceDeps(plan: { await p.propose(intent: $0, profile: $1) },
                         implement: { await i.implement(intent: $0, proposal: $1, files: $2, profile: $3) },
                         gate: { await g.assess($0) },
                         models: ["planner": planner, "implementer": implementer, "gate": gate])
    }
}

/// intent -> plan -> implementation in a worktree -> floor + gate -> quiet pass or pending card. Always returns a card
/// (status `failed` when a step failed before there was anything to review) so nothing disappears silently.
public struct SliceRunner: Sendable {
    public let workspace: Workspace
    public let inbox: CardInbox
    public let ledgerDirectory: URL
    public let limits: LedgerLimits
    public let deps: SliceDeps
    public let profile: RiskProfile

    public init(workspace: Workspace, deps: SliceDeps, profile: RiskProfile = .light, limits: LedgerLimits = .perRun) {
        self.workspace = workspace
        self.inbox = CardInbox(directory: workspace.repo.appendingPathComponent(".hitm/inbox"))
        self.ledgerDirectory = workspace.repo.appendingPathComponent(".hitm/runs")
        self.limits = limits; self.deps = deps; self.profile = profile
    }

    static func newID() -> String { "c" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12) }

    /// Highest class found in the plan, the summary, the paths and each added line, with a note on what raised it.
    static func floorClass(proposal: Proposal, summary: String, diff: Workspace.Diff) -> (ActionClass, String?) {
        var best = proposal.overallClass
        var note: String?
        func consider(_ text: String, _ source: String) {
            let c = ActionClassifier.minimumClass(forStepText: text)
            if ActionClassifier.severity(c) > ActionClassifier.severity(best) {
                best = c; note = "\(source) looks like \(c.rawValue): \(GateResponse.sanitize(text).prefix(100))"
            }
        }
        consider(summary, "The change summary")
        for p in diff.paths { consider(p, "A changed path") }
        for l in diff.addedLineTexts { consider(l, "An added line") }
        return (best, note)
    }

    public func run(intent: String) async -> ReviewCard {
        let id = Self.newID()
        let ledger = CallLedger(fileURL: ledgerDirectory.appendingPathComponent("\(id).jsonl"), limits: limits)
        var branchCreated = false

        func failed(_ why: String, title: String = "Run did not produce a change", steps: [CardStep] = []) -> ReviewCard {
            ReviewCard(id: id, intent: intent, title: title, steps: steps, overallClass: .routine, branch: nil, changedPaths: [],
                       diff: "", diffTruncated: false, addedLines: 0, removedLines: 0, needsHuman: false, detailLevel: 0,
                       reasons: [why], gateFailed: false, models: deps.models, status: .failed)
        }
        func finish(_ c: ReviewCard) -> ReviewCard {
            try? inbox.write(c)
            try? inbox.appendEvent(kind: c.status.rawValue, cardID: c.id, by: "system")
            return c
        }
        func abort(_ why: String, title: String = "Run did not produce a change", steps: [CardStep] = []) -> ReviewCard {
            if branchCreated { try? workspace.discard(id: id) }
            return finish(failed(why, title: title, steps: steps))
        }
        func describe(_ e: Error) -> String {
            switch e as? LedgerError {
            case .budgetExceeded(let w)?: return "Call budget reached (\(w)); nothing more was sent"
            case .unresolvedCall?: return "An earlier call has no receipt; nothing more was sent"
            default: return "The call ledger could not be used; nothing was sent"
            }
        }

        // 1. Planner
        let planInputHash = CallLedger.sha256Hex([intent])
        let plan: Result<Proposal, PlannerError>
        do {
            plan = try await ledger.run(role: "Planner", model: deps.models["planner"] ?? "?", inputSHA256: planInputHash, maxTokens: PlannerAgent.maxTokens) {
                await deps.plan(intent, profile)
            }
        } catch { return abort(describe(error)) }
        guard case .success(let proposal) = plan else { return abort("Planner gave no usable plan: \(plan)") }
        let steps = proposal.effectiveSteps.map { CardStep(text: $0.text, claimedClass: $0.claimedClass, effectiveClass: $0.effectiveClass) }

        // 2. Implementer, in an isolated worktree
        let files: [String: String]
        do { files = try workspace.readableFiles() } catch { return abort("Could not read the repo files", title: proposal.title, steps: steps) }
        let implHash = CallLedger.sha256Hex(ImplementerAgent.messages(intent: intent, proposal: proposal, files: files).map(\.content))
        let impl: Result<ChangeSet, ImplementerError>
        do {
            impl = try await ledger.run(role: "Implementer", model: deps.models["implementer"] ?? "?", inputSHA256: implHash, maxTokens: ImplementerAgent.maxTokens) {
                await deps.implement(intent, proposal, files, profile)
            }
        } catch { return abort(describe(error), title: proposal.title, steps: steps) }
        guard case .success(let changes) = impl else { return abort("Implementer gave no usable change: \(impl)", title: proposal.title, steps: steps) }

        let diff: Workspace.Diff
        do {
            _ = try workspace.prepare(id: id); branchCreated = true
            try workspace.apply(changes, id: id)
            diff = try workspace.diff(id: id)
        } catch WorkspaceError.noChange {
            return abort("The implementer's files were identical to the repo; nothing changed", title: proposal.title, steps: steps)
        } catch { return abort("Could not apply the change in a worktree: \(error)", title: proposal.title, steps: steps) }

        // 3. Floor + gate
        let (overall, floorNote) = Self.floorClass(proposal: proposal, summary: changes.summary, diff: diff)
        let floor = FloorGate.evaluate(overall, profile: profile)
        let request = GateRequest.make(actionClass: overall, profileName: profile.name, filePaths: diff.paths,
                                       changeSize: diff.added + diff.removed, agentConfidence: nil, overrideHistory: "",
                                       summary: GateResponse.sanitize(proposal.title + ". " + changes.summary),
                                       profileSensitive: profile.isSensitive)
        let gateInputHash = CallLedger.sha256Hex([String(decoding: (try? JSONEncoder().encode(request)) ?? Data(), as: UTF8.self)])
        let gateResult: Result<GateResponse, GateError>
        do {
            gateResult = try await ledger.run(role: "Gate", model: deps.models["gate"] ?? "?", inputSHA256: gateInputHash, maxTokens: OpenRouterGateClient.maxTokens) {
                await deps.gate(request)
            }
        } catch {
            // No gate answer is possible; fail closed to a human.
            gateResult = .failure(.unavailable)
        }
        let decision = GateDecision.combine(floor: floor, gate: gateResult)
        var reasons = decision.reasons
        if let floorNote { reasons.insert(floorNote, at: 0) }

        var card = ReviewCard(id: id, intent: intent, title: proposal.title, steps: steps, overallClass: overall, branch: Workspace.branchName(id),
                              changedPaths: diff.paths, diff: diff.text, diffTruncated: diff.truncated, addedLines: diff.added,
                              removedLines: diff.removed, needsHuman: decision.needsHuman, detailLevel: decision.detailLevel,
                              reasons: reasons, gateFailed: decision.gateFailed, models: deps.models, status: .pending)
        if !decision.needsHuman {
            // Quiet pass: kept on its branch only; a person still merges it.
            do { try workspace.commit(id: id, message: proposal.title); card.status = .quietPassed }
            catch { card.status = .pending; card = ReviewCard(id: id, intent: intent, title: proposal.title, steps: steps, overallClass: overall,
                branch: Workspace.branchName(id), changedPaths: diff.paths, diff: diff.text, diffTruncated: diff.truncated, addedLines: diff.added,
                removedLines: diff.removed, needsHuman: true, detailLevel: max(2, decision.detailLevel),
                reasons: ["Could not record the change on its branch, so it is asking you"] + reasons, gateFailed: decision.gateFailed,
                models: deps.models, status: .pending) }
        }
        return finish(card)
    }

    /// A named human decides a pending card. Pass commits the work on its branch (never main); reject removes the worktree and branch.
    public func resolve(cardID: String, pass: Bool, by name: String) throws -> ReviewCard {
        let before = try inbox.load(cardID)
        let decided = try inbox.decide(cardID, to: pass ? .passed : .rejected, by: name)
        do {
            if pass { try workspace.commit(id: cardID, message: before.title) } else { try workspace.discard(id: cardID) }
        } catch {
            try? inbox.appendEvent(kind: "action-failed", cardID: cardID, by: "system")
            throw error
        }
        return decided
    }
}
#endif
