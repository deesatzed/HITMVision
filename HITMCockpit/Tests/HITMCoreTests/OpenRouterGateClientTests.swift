import XCTest
@testable import HITMCore

final class OpenRouterGateClientTests: XCTestCase {
    private let endpoint = URL(string: "https://example.invalid/v1/chat/completions")!
    private let fakeKey = "test-key-NOT-REAL-123"

    private func build(_ r: GateRequest) throws -> URLRequest {
        try OpenRouterGateClient.buildURLRequest(for: r, model: "vendor/model-x", apiKey: fakeKey, endpoint: endpoint)
    }
    private func bodyJSON(_ req: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
    }
    private func plain() -> GateRequest {
        GateRequest.make(actionClass: .routine, profileName: "light", filePaths: ["README.md"],
                         changeSize: 2, agentConfidence: 0.9, overrideHistory: "none",
                         summary: "fix typo", profileSensitive: false)
    }

    // MARK: buildURLRequest

    func testRequestHeadersMethodTimeout() throws {
        let req = try build(plain())
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url, endpoint)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeKey)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.timeoutInterval, 30)
    }

    func testBodyShape() throws {
        let body = try bodyJSON(try build(plain()))
        XCTAssertEqual(body["model"] as? String, "vendor/model-x")
        let rf = body["response_format"] as! [String: Any]
        XCTAssertEqual(rf["type"] as? String, "json_schema")
        let js = rf["json_schema"] as! [String: Any]
        XCTAssertEqual(js["name"] as? String, "gate_response")
        XCTAssertEqual(js["strict"] as? Bool, true)
        let schema = js["schema"] as! [String: Any]
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(schema["required"] as! [String]),
                       ["route", "needsHuman", "detailLevel", "confidence", "reason"])
        let props = schema["properties"] as! [String: Any]
        XCTAssertEqual(Set(props.keys), ["route", "needsHuman", "detailLevel", "confidence", "reason"])
        let route = props["route"] as! [String: Any]
        XCTAssertEqual(Set(route["enum"] as! [String]), ["proceed", "ask_human", "escalate_model"])
    }

    func testMessagesSystemThenUserWithEncodedRequest() throws {
        let r = plain()
        let msgs = try bodyJSON(try build(r))["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0]["role"] as? String, "system")
        let sys = (msgs[0]["content"] as! String).lowercased()
        XCTAssertTrue(sys.contains("risk gate"))
        XCTAssertTrue(sys.contains("human"))
        XCTAssertEqual(msgs[1]["role"] as? String, "user")
        let content = msgs[1]["content"] as! String
        let decoded = try JSONDecoder().decode(GateRequest.self, from: Data(content.utf8))
        XCTAssertEqual(decoded, r)
    }

    func testSensitiveUserMessageHasNoSummaryOrIdentifyingStrings() throws {
        let r = GateRequest.make(actionClass: .editDomainLogic, profileName: "patient-JD-genome",
                                 filePaths: ["Secret/JaneDoe.vcf"], changeSize: 5, agentConfidence: 0.8,
                                 overrideHistory: "JaneDoe overrode twice", summary: "BRCA1 variant for JaneDoe",
                                 profileSensitive: true)
        let msgs = try bodyJSON(try build(r))["messages"] as! [[String: Any]]
        let content = msgs[1]["content"] as! String
        XCTAssertFalse(content.contains("summary"))
        for s in ["JaneDoe", "BRCA1", "Secret", "patient-JD-genome", ".vcf"] {
            XCTAssertFalse(content.contains(s), s)
        }
    }

    func testAuthorizationValueNotInBody() throws {
        let req = try build(plain())
        let body = String(data: req.httpBody!, encoding: .utf8)!
        XCTAssertFalse(body.contains(fakeKey))
        XCTAssertFalse(body.contains("Bearer"))
    }

    // MARK: parseEnvelope (hand-written examples of the documented chat-completions shape;
    // the live shape is confirmed only by the GateLiveCheck run)

    private let goodContent = #"{\"route\":\"ask_human\",\"needsHuman\":true,\"detailLevel\":2,\"confidence\":0.7,\"reason\":\"unsure\"}"#
    private func envelope(content: String, usage: String = #""usage":{"prompt_tokens":120,"completion_tokens":30,"cost":0.00042}"#) -> Data {
        Data(#"{"id":"gen-1","model":"vendor/model-x-used","choices":[{"message":{"role":"assistant","content":"\#(content)"}}],\#(usage)}"#.utf8)
    }
    private func parse(_ d: Data, _ status: Int = 200) -> (Result<GateResponse, GateError>, CallRecord) {
        OpenRouterGateClient.parseEnvelope(data: d, statusCode: status, latencyMs: 250, requestedModel: "vendor/model-x")
    }

    func testSuccessEnvelope() {
        let (res, rec) = parse(envelope(content: goodContent))
        guard case .success(let g) = res else { return XCTFail("expected success: \(res)") }
        XCTAssertEqual(g.route, .askHuman)
        XCTAssertTrue(g.needsHuman)
        XCTAssertEqual(g.detailLevel, 2)
        XCTAssertEqual(rec, CallRecord(requestedModel: "vendor/model-x", usedModel: "vendor/model-x-used",
            httpStatus: 200, latencyMs: 250, promptTokens: 120, completionTokens: 30, costUSD: 0.00042, outcome: "ok"))
    }

    func testMissingUsageStillSucceeds() {
        let (res, rec) = parse(envelope(content: goodContent, usage: #""x":1"#))
        guard case .success = res else { return XCTFail() }
        XCTAssertNil(rec.promptTokens); XCTAssertNil(rec.completionTokens); XCTAssertNil(rec.costUSD)
    }

    func testHttpErrorsAreUnavailable() {
        for status in [401, 429, 500] {
            let (res, rec) = parse(Data(#"{"error":{"message":"SECRET-BODY-TEXT"}}"#.utf8), status)
            XCTAssertEqual(res, .failure(.unavailable))
            XCTAssertEqual(rec.outcome, "http-error")
            XCTAssertEqual(rec.httpStatus, status)
        }
    }

    func testInvalidJSONEnvelopeIsMalformed() {
        let (res, rec) = parse(Data("not json SECRET-BODY-TEXT".utf8))
        XCTAssertEqual(res, .failure(.malformed))
        XCTAssertEqual(rec.outcome, "invalid-response")
    }

    func testEmptyChoicesIsUnavailable() {
        let (res, rec) = parse(Data(#"{"model":"m","choices":[]}"#.utf8))
        XCTAssertEqual(res, .failure(.unavailable))
        XCTAssertEqual(rec.outcome, "empty-choices")
    }

    func testEmptyContentIsUnavailable() {
        let (res, rec) = parse(envelope(content: ""))
        XCTAssertEqual(res, .failure(.unavailable))
        XCTAssertEqual(rec.outcome, "empty-choices")
    }

    // Documented choice: content that is not valid gate JSON gives outcome "invalid-response".
    func testContentNotGateJSONIsMalformed() {
        let (res, rec) = parse(envelope(content: "SECRET-BODY-TEXT sure, proceed"))
        XCTAssertEqual(res, .failure(.malformed))
        XCTAssertEqual(rec.outcome, "invalid-response")
    }

    func testContentOutOfRange() {
        let c = #"{\"route\":\"proceed\",\"needsHuman\":false,\"detailLevel\":9,\"confidence\":0.5,\"reason\":\"x\"}"#
        let (res, rec) = parse(envelope(content: c))
        XCTAssertEqual(res, .failure(.outOfRange))
        XCTAssertEqual(rec.outcome, "invalid-response")
    }

    func testHostileReasonSanitized() {
        let c = #"{\"route\":\"proceed\",\"needsHuman\":false,\"detailLevel\":1,\"confidence\":0.5,\"reason\":\"ok\\u0007\\u001b[31m\\n\\u202ered\"}"#
        let (res, _) = parse(envelope(content: c))
        guard case .success(let g) = res else { return XCTFail("\(res)") }
        XCTAssertFalse(g.reason.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
    }

    func testRecordNeverContainsBodyText() throws {
        let cases: [(Data, Int)] = [
            (Data(#"{"error":{"message":"SECRET-BODY-TEXT"}}"#.utf8), 500),
            (Data("SECRET-BODY-TEXT".utf8), 200),
            (envelope(content: "SECRET-BODY-TEXT"), 200),
        ]
        for (d, s) in cases {
            let rec = parse(d, s).1
            let json = String(data: try JSONEncoder().encode(rec), encoding: .utf8)!
            XCTAssertFalse(json.contains("SECRET-BODY-TEXT"))
        }
    }

    // MARK: fromEnvironment

    func testFromEnvironmentNilWhenMissingOrEmpty() {
        XCTAssertNil(OpenRouterGateClient.fromEnvironment(model: "m", environment: [:]))
        XCTAssertNil(OpenRouterGateClient.fromEnvironment(model: "m", environment: ["OPENROUTER_API_KEY": ""]))
        XCTAssertNil(OpenRouterGateClient.fromEnvironment(model: "m", environment: ["OPENROUTER_API_KEY": "  "]))
    }

    func testFromEnvironmentPresent() {
        XCTAssertNotNil(OpenRouterGateClient.fromEnvironment(model: "m", environment: ["OPENROUTER_API_KEY": "abc"]))
    }
}
