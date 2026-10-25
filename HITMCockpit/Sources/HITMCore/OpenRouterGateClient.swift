import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-call log entry. Holds no request body, no response body and no key.
public struct CallRecord: Codable, Equatable, Sendable {
    public let requestedModel: String
    public let usedModel: String?
    public let httpStatus: Int?
    public let latencyMs: Int
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let costUSD: Double?
    /// "ok", "http-error", "network-error", "timeout", "empty-choices", "invalid-response"
    public let outcome: String

    public init(requestedModel: String, usedModel: String?, httpStatus: Int?, latencyMs: Int,
                promptTokens: Int?, completionTokens: Int?, costUSD: Double?, outcome: String) {
        self.requestedModel = requestedModel; self.usedModel = usedModel; self.httpStatus = httpStatus
        self.latencyMs = latencyMs; self.promptTokens = promptTokens
        self.completionTokens = completionTokens; self.costUSD = costUSD; self.outcome = outcome
    }
}

/// Refuses every redirect, so the Authorization header can never be forwarded to another host.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct InsecureEndpointError: Error {}
struct InvalidSchemaError: Error {}

public struct ChatMessage: Equatable, Sendable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

/// Generic, hardened OpenRouter chat-completions transport (structured JSON output).
/// Ephemeral session, 30 s deadline, https only, no redirects; records never hold the key or any body.
public struct OpenRouterTransport: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let defaultEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private let apiKey: String
    public let model: String
    private let endpoint: URL
    private let session: URLSession

    public init(apiKey: String, model: String, endpoint: URL = OpenRouterTransport.defaultEndpoint) {
        self.apiKey = apiKey; self.model = model; self.endpoint = endpoint
        self.session = Self.makeSession()
    }

    // The key must never appear in print, interpolation or dump.
    public var description: String { "OpenRouterTransport(model: \(model))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": model], displayStyle: .struct) }

    /// Dedicated ephemeral session: 30 s total deadline, no redirects, no cache.
    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 30
        c.urlCache = nil
        return URLSession(configuration: c, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    static func outcome(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let e = error as? URLError {
            if e.code == .timedOut { return "timeout" }
            if e.code == .cancelled { return "cancelled" }
        }
        return "network-error"
    }

    /// Non-negative whole number that fits an Int; Bool, strings, fractions, negatives, NaN/inf give nil.
    static func parseCount(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d == d.rounded(), d < 1e15 else { return nil }
        return Int(d)
    }

    static func parseCost(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite && d >= 0 ? d : nil
    }

    static func sanitizeModel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let clean = GateResponse.sanitize(raw)
        var out = String.UnicodeScalarView()
        out.append(contentsOf: clean.unicodeScalars.prefix(100))
        let s = String(out)
        return s.isEmpty ? nil : s
    }

    /// `schemaJSON` is a pre-encoded JSON Schema object.
    static func buildURLRequest(messages: [ChatMessage], schemaName: String, schemaJSON: Data, maxTokens: Int?,
                                model: String, apiKey: String, endpoint: URL) throws -> URLRequest {
        guard endpoint.scheme?.lowercased() == "https" else { throw InsecureEndpointError() }
        guard let schema = try? JSONSerialization.jsonObject(with: schemaJSON), schema is [String: Any]
        else { throw InvalidSchemaError() }
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": schemaName, "strict": true, "schema": schema] as [String: Any],
            ] as [String: Any],
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// Outcomes: "ok" (content present), "http-error", "invalid-response" (unparseable envelope),
    /// "empty-choices". Content is nil for every outcome except "ok".
    static func parseEnvelope(data: Data, statusCode: Int, latencyMs: Int,
                              requestedModel: String) -> (content: String?, record: CallRecord) {
        func record(_ outcome: String, used: String? = nil, usage: [String: Any]? = nil) -> CallRecord {
            CallRecord(requestedModel: requestedModel, usedModel: used, httpStatus: statusCode,
                       latencyMs: latencyMs,
                       promptTokens: parseCount(usage?["prompt_tokens"]),
                       completionTokens: parseCount(usage?["completion_tokens"]),
                       costUSD: parseCost(usage?["cost"]),
                       outcome: outcome)
        }
        guard statusCode == 200 else { return (nil, record("http-error")) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, record("invalid-response"))
        }
        let used = sanitizeModel(obj["model"] as? String)
        let usage = obj["usage"] as? [String: Any]
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            return (nil, record("empty-choices", used: used, usage: usage))
        }
        return (content, record("ok", used: used, usage: usage))
    }

    public func complete(messages: [ChatMessage], schemaName: String, schemaJSON: Data,
                         maxTokens: Int?) async -> (content: String?, record: CallRecord) {
        let start = ContinuousClock.now
        func ms() -> Int {
            let d = ContinuousClock.now - start
            return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }
        func fail(_ outcome: String) -> (content: String?, record: CallRecord) {
            (nil, CallRecord(requestedModel: model, usedModel: nil, httpStatus: nil,
                latencyMs: ms(), promptTokens: nil, completionTokens: nil, costUSD: nil, outcome: outcome))
        }
        let urlRequest: URLRequest
        do {
            urlRequest = try Self.buildURLRequest(messages: messages, schemaName: schemaName, schemaJSON: schemaJSON,
                                                  maxTokens: maxTokens, model: model, apiKey: apiKey, endpoint: endpoint)
        } catch { return fail("request-error") }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return Self.parseEnvelope(data: data, statusCode: status, latencyMs: ms(), requestedModel: model)
        } catch {
            return fail(Self.outcome(for: Task.isCancelled ? CancellationError() : error))  // error text deliberately dropped: it could echo the URL/headers
        }
    }
}

public struct OpenRouterGateClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let defaultEndpoint = OpenRouterTransport.defaultEndpoint
    /// Small bound: the gate answer is a short JSON object.
    static let maxTokens = 400

    private let transport: OpenRouterTransport
    private let model: String

    public init(apiKey: String, model: String, endpoint: URL = OpenRouterGateClient.defaultEndpoint) {
        self.model = model
        self.transport = OpenRouterTransport(apiKey: apiKey, model: model, endpoint: endpoint)
    }

    public var description: String { "OpenRouterGateClient(model: \(model))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": model], displayStyle: .struct) }

    static func makeSession() -> URLSession { OpenRouterTransport.makeSession() }
    static func outcome(for error: Error) -> String { OpenRouterTransport.outcome(for: error) }
    static func parseCount(_ v: Any?) -> Int? { OpenRouterTransport.parseCount(v) }
    static func parseCost(_ v: Any?) -> Double? { OpenRouterTransport.parseCost(v) }
    static func sanitizeModel(_ raw: String?) -> String? { OpenRouterTransport.sanitizeModel(raw) }

    /// nil when OPENROUTER_API_KEY is missing or blank. The key is never printed.
    public static func fromEnvironment(model: String) -> OpenRouterGateClient? {
        fromEnvironment(model: model, environment: ProcessInfo.processInfo.environment)
    }

    public static func fromEnvironment(model: String, environment: [String: String]) -> OpenRouterGateClient? {
        guard let key = environment["OPENROUTER_API_KEY"],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return OpenRouterGateClient(apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines), model: model)
    }

    /// Same environment key lookup, for building the generic transport (e.g. for the Planner).
    public static func transportFromEnvironment(model: String) -> OpenRouterTransport? {
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return OpenRouterTransport(apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines), model: model)
    }

    static let systemPrompt = """
        You are a risk gate for a software-engineering agent. You are given JSON request metadata \
        describing an action the agent wants to take. Answer ONLY with JSON matching the supplied schema. \
        Ask for a human whenever you are unsure. Never lower safety. \
        If agentConfidence is absent it means the confidence was not reported; do not treat that as low confidence.
        """

    static let schemaName = "gate_response"

    static func schemaJSON() -> Data {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "route": ["type": "string", "enum": ["proceed", "ask_human", "escalate_model"]],
                "needsHuman": ["type": "boolean"],
                "detailLevel": ["type": "integer", "minimum": 0, "maximum": 3],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "reason": ["type": "string"],
            ] as [String: Any],
            "required": ["route", "needsHuman", "detailLevel", "confidence", "reason"],
            "additionalProperties": false,
        ]
        return (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
    }

    static func buildURLRequest(for request: GateRequest, model: String, apiKey: String,
                                endpoint: URL) throws -> URLRequest {
        let requestJSON = try JSONEncoder().encode(request)
        let userContent = String(decoding: requestJSON, as: UTF8.self)
        return try OpenRouterTransport.buildURLRequest(
            messages: [ChatMessage(role: "system", content: systemPrompt),
                       ChatMessage(role: "user", content: userContent)],
            schemaName: schemaName, schemaJSON: schemaJSON(), maxTokens: maxTokens,
            model: model, apiKey: apiKey, endpoint: endpoint)
    }

    /// Outcome "invalid-response" covers both an unparseable envelope and gate content that fails
    /// strict decoding (malformed or out of range); the failure kind distinguishes them.
    static func parseEnvelope(data: Data, statusCode: Int, latencyMs: Int,
                              requestedModel: String) -> (Result<GateResponse, GateError>, CallRecord) {
        let (content, rec) = OpenRouterTransport.parseEnvelope(data: data, statusCode: statusCode,
                                                               latencyMs: latencyMs, requestedModel: requestedModel)
        return interpret(content: content, record: rec)
    }

    static func interpret(content: String?, record rec: CallRecord) -> (Result<GateResponse, GateError>, CallRecord) {
        guard let content else {
            return (.failure(rec.outcome == "invalid-response" ? .malformed : .unavailable), rec)
        }
        let result = GateResponse.decodeStrict(Data(content.utf8))
        switch result {
        case .success: return (result, rec)
        case .failure:
            return (result, CallRecord(requestedModel: rec.requestedModel, usedModel: rec.usedModel,
                httpStatus: rec.httpStatus, latencyMs: rec.latencyMs, promptTokens: rec.promptTokens,
                completionTokens: rec.completionTokens, costUSD: rec.costUSD, outcome: "invalid-response"))
        }
    }

    public func assess(_ request: GateRequest) async -> (Result<GateResponse, GateError>, CallRecord) {
        guard let encoded = try? JSONEncoder().encode(request) else {
            return (.failure(.unavailable), CallRecord(requestedModel: model, usedModel: nil, httpStatus: nil,
                latencyMs: 0, promptTokens: nil, completionTokens: nil, costUSD: nil, outcome: "request-error"))
        }
        let userContent = String(decoding: encoded, as: UTF8.self)
        let (content, rec) = await transport.complete(
            messages: [ChatMessage(role: "system", content: Self.systemPrompt),
                       ChatMessage(role: "user", content: userContent)],
            schemaName: Self.schemaName, schemaJSON: Self.schemaJSON(), maxTokens: Self.maxTokens)
        return Self.interpret(content: content, record: rec)
    }
}
