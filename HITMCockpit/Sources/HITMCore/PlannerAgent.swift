import Foundation

public struct PlannerAgent: Sendable {
    private let transport: OpenRouterTransport
    static let schemaName = "proposal"
    static let maxTokens = 1500

    public init(transport: OpenRouterTransport) { self.transport = transport }

    static let systemPrompt = """
        You are a planning agent for a software-engineering team. You only PROPOSE a plan; you never execute \
        anything. Answer ONLY with JSON matching the supplied strict json_schema: a short title, 1 to 8 steps \
        (each with text and claimedClass), up to 5 risks and up to 5 questions. Set claimedClass honestly: \
        mark any step that deletes data, deploys, sends data outside, or changes safety checks or core logic \
        with the matching class instead of routine.
        """

    static func schemaJSON() -> Data {
        let classes = ActionClass.allCases.map(\.rawValue)
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "steps": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["text": ["type": "string"], "claimedClass": ["type": "string", "enum": classes]],
                    "required": ["text", "claimedClass"],
                    "additionalProperties": false,
                ] as [String: Any]],
                "risks": ["type": "array", "items": ["type": "string"]],
                "questions": ["type": "array", "items": ["type": "string"]],
            ] as [String: Any],
            "required": ["title", "steps", "risks", "questions"],
            "additionalProperties": false,
        ]
        return (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
    }

    /// Strip Cc/Cf, cap at 2000 scalars.
    static func cleanIntent(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        for u in raw.unicodeScalars.prefix(2000) {
            if u.properties.isWhitespace { out.append(" "); continue }
            switch u.properties.generalCategory {
            case .control, .format: continue
            default: out.append(u)
            }
        }
        return String(out)
    }

    static func messages(intent: String) -> [ChatMessage] {
        [ChatMessage(role: "system", content: systemPrompt), ChatMessage(role: "user", content: cleanIntent(intent))]
    }

    static func buildURLRequest(intent: String, model: String, apiKey: String, endpoint: URL) throws -> URLRequest {
        try OpenRouterTransport.buildURLRequest(messages: messages(intent: intent), schemaName: schemaName,
            schemaJSON: schemaJSON(), maxTokens: maxTokens, model: model, apiKey: apiKey, endpoint: endpoint)
    }

    /// Intent text is sent only when `profileSensitive` is false; otherwise the transport is never touched.
    public func propose(intent: String, profile: RiskProfile,
                        profileSensitive: Bool) async -> (Result<Proposal, PlannerError>, CallRecord?) {
        if profileSensitive { return (.failure(.blockedBySensitiveProfile), nil) }
        let (content, record) = await transport.complete(messages: Self.messages(intent: intent),
            schemaName: Self.schemaName, schemaJSON: Self.schemaJSON(), maxTokens: Self.maxTokens)
        guard let content else { return (.failure(.unavailable), record) }
        let result = Proposal.decodeStrict(Data(content.utf8))
        if case .failure = result {
            return (result, CallRecord(requestedModel: record.requestedModel, usedModel: record.usedModel,
                httpStatus: record.httpStatus, latencyMs: record.latencyMs, promptTokens: record.promptTokens,
                completionTokens: record.completionTokens, costUSD: record.costUSD, outcome: "invalid-response"))
        }
        return (result, record)
    }
}

public enum ProposalGate {
    /// `agentConfidence` defaults to 0.5: a placeholder, because the planner reports no calibrated confidence.
    public static func gateRequest(for proposal: Proposal, profile: RiskProfile, profileSensitive: Bool,
                                   agentConfidence: Double = 0.5) -> GateRequest {
        GateRequest.make(actionClass: proposal.overallClass, profileName: profile.name, filePaths: [],
                         changeSize: proposal.steps.count, agentConfidence: agentConfidence,
                         overrideHistory: "", summary: proposal.title, profileSensitive: profileSensitive)
    }

    public static func decide(proposal: Proposal, profile: RiskProfile,
                              gate: Result<GateResponse, GateError>) -> GateDecision {
        GateDecision.combine(floor: FloorGate.evaluate(proposal.overallClass, profile: profile), gate: gate)
    }
}
