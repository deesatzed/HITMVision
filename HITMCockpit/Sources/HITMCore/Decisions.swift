import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A yes/no ("noul") question for an OpenRouter decision model. The answer is the probability of "true".
public struct DecisionsBooleanQuestion: Equatable, Sendable {
    public let id: String
    public let instructions: String
    public let whenFalse: String
    public let whenTrue: String

    public init(id: String, instructions: String, whenFalse: String, whenTrue: String) {
        self.id = id; self.instructions = instructions; self.whenFalse = whenFalse; self.whenTrue = whenTrue
    }
}

public struct DecisionsResult: Equatable, Sendable {
    /// Question id to probability of "true", each finite and within 0...1. Invalid answers are dropped.
    public let probabilities: [String: Double]
    /// The company OpenRouter says served the call, sanitized; nil when not reported.
    public let provider: String?
}

/// Hardened transport for OpenRouter's alpha Decisions endpoint. Same limits as `OpenRouterTransport`:
/// ephemeral session, 30 s deadline, https only, no redirects; records never hold the key or any body.
public struct OpenRouterDecisionsTransport: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Not under /api/v1: that path returns 404 (measured 2026-10-30).
    public static let defaultEndpoint = URL(string: "https://openrouter.ai/api/alpha/decisions")!

    private let apiKey: String
    public let model: String
    private let endpoint: URL
    private let session: URLSession

    public init(apiKey: String, model: String, endpoint: URL = OpenRouterDecisionsTransport.defaultEndpoint) {
        self.apiKey = apiKey; self.model = model; self.endpoint = endpoint
        self.session = OpenRouterTransport.makeSession()
    }

    public var description: String { "OpenRouterDecisionsTransport(model: \(model))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": model], displayStyle: .struct) }

    /// nil when OPENROUTER_API_KEY is missing or blank. The key is never printed.
    public static func fromEnvironment(model: String) -> OpenRouterDecisionsTransport? {
        fromEnvironment(model: model, environment: ProcessInfo.processInfo.environment)
    }

    public static func fromEnvironment(model: String, environment: [String: String]) -> OpenRouterDecisionsTransport? {
        guard let key = environment["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return OpenRouterDecisionsTransport(apiKey: key, model: model)
    }

    /// `stateJSON` is a pre-encoded JSON value (object or array) that every question is about.
    static func buildURLRequest(model: String, stateJSON: Data, questions: [DecisionsBooleanQuestion],
                                apiKey: String, endpoint: URL) throws -> URLRequest {
        guard endpoint.scheme?.lowercased() == "https" else { throw InsecureEndpointError() }
        guard let state = try? JSONSerialization.jsonObject(with: stateJSON, options: [.fragmentsAllowed]),
              state is [String: Any] || state is [Any] else { throw InvalidSchemaError() }
        var qs: [String: Any] = [:]
        for q in questions {
            qs[q.id] = ["type": "noul", "instructions": q.instructions,
                        "criteria": ["false": q.whenFalse, "true": q.whenTrue]] as [String: Any]
        }
        let body: [String: Any] = ["model": model, "state": state, "questions": qs]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// Outcomes: "ok", "http-error", "invalid-response" (unparseable, or no usable yes/no answer).
    static func parseEnvelope(data: Data, statusCode: Int, latencyMs: Int,
                              requestedModel: String) -> (DecisionsResult?, CallRecord) {
        func record(_ outcome: String, used: String? = nil, usage: [String: Any]? = nil) -> CallRecord {
            CallRecord(requestedModel: requestedModel, usedModel: used, httpStatus: statusCode, latencyMs: latencyMs,
                       promptTokens: OpenRouterTransport.parseCount(usage?["input_tokens"]),
                       completionTokens: OpenRouterTransport.parseCount(usage?["output_tokens"]),
                       costUSD: OpenRouterTransport.parseCost(usage?["cost"]), outcome: outcome)
        }
        guard statusCode == 200 else { return (nil, record("http-error")) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, record("invalid-response"))
        }
        let used = OpenRouterTransport.sanitizeModel(obj["model"] as? String)
        let usage = obj["usage"] as? [String: Any]
        var probs: [String: Double] = [:]
        for (id, raw) in (obj["answers"] as? [String: Any]) ?? [:] {
            guard let a = raw as? [String: Any], a["type"] as? String == "noul",
                  let n = a["noul"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { continue }
            let p = n.doubleValue
            if p.isFinite, (0.0...1.0).contains(p) { probs[id] = p }
        }
        guard !probs.isEmpty else { return (nil, record("invalid-response", used: used, usage: usage)) }
        return (DecisionsResult(probabilities: probs, provider: OpenRouterTransport.sanitizeModel(obj["provider"] as? String)),
                record("ok", used: used, usage: usage))
    }

    public func assess(stateJSON: Data, questions: [DecisionsBooleanQuestion]) async -> (DecisionsResult?, CallRecord) {
        let start = ContinuousClock.now
        func ms() -> Int {
            let d = ContinuousClock.now - start
            return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }
        func fail(_ outcome: String) -> (DecisionsResult?, CallRecord) {
            (nil, CallRecord(requestedModel: model, usedModel: nil, httpStatus: nil, latencyMs: ms(),
                             promptTokens: nil, completionTokens: nil, costUSD: nil, outcome: outcome))
        }
        let urlRequest: URLRequest
        do {
            urlRequest = try Self.buildURLRequest(model: model, stateJSON: stateJSON, questions: questions,
                                                  apiKey: apiKey, endpoint: endpoint)
        } catch { return fail("request-error") }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return Self.parseEnvelope(data: data, statusCode: status, latencyMs: ms(), requestedModel: model)
        } catch {
            return fail(OpenRouterTransport.outcome(for: Task.isCancelled ? CancellationError() : error))
        }
    }
}
