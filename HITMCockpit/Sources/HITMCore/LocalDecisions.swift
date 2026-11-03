import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport for a decision model served on THIS machine (the `/v1/decide` shape of jev27b_mlx's server).
/// Nothing leaves the Mac: the endpoint must be loopback http(s), no redirects are followed, and a result
/// reports provider "local". One request per question; the server answers one question at a time.
public struct LocalDecisionsTransport: Sendable {
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8000/v1/decide")!
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    public let model: String
    private let endpoint: URL
    private let session: URLSession

    /// nil when the endpoint is not a loopback address: a sensitive project must never reach another host.
    public init?(model: String, endpoint: URL = LocalDecisionsTransport.defaultEndpoint) {
        guard Self.isLoopback(endpoint) else { return nil }
        self.model = model; self.endpoint = endpoint
        self.session = OpenRouterTransport.makeSession()
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

    static func buildURLRequest(stateJSON: Data, question: DecisionsBooleanQuestion, endpoint: URL) throws -> URLRequest {
        guard isLoopback(endpoint) else { throw InsecureEndpointError() }
        guard let state = try? JSONSerialization.jsonObject(with: stateJSON, options: [.fragmentsAllowed]),
              state is [String: Any] || state is [Any] else { throw InvalidSchemaError() }
        let q: [String: Any] = ["type": "noul", "instructions": question.instructions,
                                "criteria": ["false": question.whenFalse, "true": question.whenTrue]]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["state": state, "question": q], options: [.sortedKeys])
        return req
    }

    /// The server returns `probabilities` for [false, true]; P(true) is index 1. Anything else is invalid.
    static func parseProbability(data: Data) -> Double? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let options = obj["options"] as? [String], options == ["false", "true"],
              let probs = obj["probabilities"] as? [NSNumber], probs.count == 2,
              !probs.contains(where: { CFGetTypeID($0) == CFBooleanGetTypeID() }) else { return nil }
        let p = probs[1].doubleValue
        return p.isFinite && (0.0...1.0).contains(p) ? p : nil
    }

    public func assess(stateJSON: Data, questions: [DecisionsBooleanQuestion]) async -> (DecisionsResult?, CallRecord) {
        let start = ContinuousClock.now
        func ms() -> Int {
            let d = ContinuousClock.now - start
            return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }
        func record(_ outcome: String, status: Int? = nil) -> CallRecord {
            CallRecord(requestedModel: model, usedModel: nil, httpStatus: status, latencyMs: ms(),
                       promptTokens: nil, completionTokens: nil, costUSD: 0, outcome: outcome)
        }
        var probs: [String: Double] = [:]
        for q in questions {
            guard let req = try? Self.buildURLRequest(stateJSON: stateJSON, question: q, endpoint: endpoint) else {
                return (nil, record("request-error"))
            }
            do {
                let (data, response) = try await session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200 else { return (nil, record("http-error", status: status)) }
                guard let p = Self.parseProbability(data: data) else { return (nil, record("invalid-response", status: status)) }
                probs[q.id] = p
            } catch {
                return (nil, record(OpenRouterTransport.outcome(for: Task.isCancelled ? CancellationError() : error)))
            }
        }
        guard !probs.isEmpty else { return (nil, record("invalid-response")) }
        return (DecisionsResult(probabilities: probs, provider: "local"), record("ok", status: 200))
    }
}
