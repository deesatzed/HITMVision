import XCTest
@testable import HITMCore

final class OpenRouterGateClientHardeningTests: XCTestCase {
    private func env(_ usage: String, model: String = #""vendor/m""#) -> Data {
        Data(#"{"model":\#(model),"choices":[{"message":{"content":"{\"route\":\"proceed\",\"needsHuman\":false,\"detailLevel\":1,\"confidence\":0.5,\"reason\":\"ok\"}"}}],"usage":\#(usage)}"#.utf8)
    }
    private func rec(_ d: Data) -> CallRecord {
        OpenRouterGateClient.parseEnvelope(data: d, statusCode: 200, latencyMs: 1, requestedModel: "m").1
    }

    // 1. session
    func testSessionDeadlinesAndNoSharedSession() {
        let s = OpenRouterGateClient.makeSession()
        XCTAssertEqual(s.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(s.configuration.timeoutIntervalForResource, 30)
        XCTAssertFalse(s === URLSession.shared)
        XCTAssertNil(s.configuration.urlCache)
    }

    // 3. redaction
    func testKeyNeverInDescriptionOrDump() {
        let key = "zqXK-9f3a7c-DISTINCTKEY"
        let c = OpenRouterGateClient(apiKey: key, model: "vendor/model-x")
        var dumped = ""
        dump(c, to: &dumped)
        for text in ["\(c)", String(describing: c), String(reflecting: c), dumped] {
            XCTAssertTrue(text.contains("vendor/model-x"))
            for n in 6...key.count {
                XCTAssertFalse(text.contains(String(key.prefix(n))), "leaked prefix \(n)")
            }
        }
    }

    // 5. usedModel sanitizing
    func testUsedModelSanitized() {
        let r = rec(env("{}", model: #""vendor\u001b[31m/m\n‮odel  x""#))
        XCTAssertEqual(r.usedModel, "vendor[31m/m odel x")
        XCTAssertNil(rec(env("{}", model: #""\u0007\n‮""#)).usedModel)
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(rec(env("{}", model: "\"\(long)\"")).usedModel?.unicodeScalars.count, 100)
    }

    // 6. usage parsing
    func testTokenParsing() {
        XCTAssertEqual(rec(env(#"{"prompt_tokens":12,"completion_tokens":0}"#)).promptTokens, 12)
        XCTAssertEqual(rec(env(#"{"prompt_tokens":12,"completion_tokens":0}"#)).completionTokens, 0)
        for bad in ["true", "false", "-1", "1.5", #""7""#, "null", "[]"] {
            let r = rec(env(#"{"prompt_tokens":\#(bad),"completion_tokens":\#(bad)}"#))
            XCTAssertNil(r.promptTokens, bad); XCTAssertNil(r.completionTokens, bad)
            XCTAssertEqual(r.outcome, "ok", bad)
        }
    }
    func testCostParsing() {
        XCTAssertEqual(rec(env(#"{"cost":0.5}"#)).costUSD, 0.5)
        XCTAssertEqual(rec(env(#"{"cost":0}"#)).costUSD, 0)
        for bad in ["true", "-0.1", #""0.1""#, "null"] {
            XCTAssertNil(rec(env(#"{"cost":\#(bad)}"#)).costUSD, bad)
        }
        XCTAssertNil(OpenRouterGateClient.parseCost(Double.nan))
        XCTAssertNil(OpenRouterGateClient.parseCost(Double.infinity))
        XCTAssertNil(OpenRouterGateClient.parseCount(Double.nan))
        XCTAssertNil(OpenRouterGateClient.parseCount(Double.infinity))
        XCTAssertNil(OpenRouterGateClient.parseCount(1e30))
    }

    // 7. request-error
    private func bad(confidence: Double) -> GateRequest {
        GateRequest.make(actionClass: .routine, profileName: "light", filePaths: [], changeSize: 1,
                         agentConfidence: confidence, overrideHistory: "", summary: nil, profileSensitive: false)
    }
    func testNonFiniteConfidenceThrowsAndAssessReportsRequestError() async {
        let url = URL(string: "https://example.invalid/x")!
        for c in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try OpenRouterGateClient.buildURLRequest(for: bad(confidence: c), model: "m", apiKey: "k", endpoint: url))
            let (res, rec) = await OpenRouterGateClient(apiKey: "k", model: "m", endpoint: url).assess(bad(confidence: c))
            XCTAssertEqual(res, .failure(.unavailable))
            XCTAssertEqual(rec.outcome, "request-error")
            XCTAssertNil(rec.httpStatus)
        }
    }

    // 8. error mapping
    func testOutcomeMapping() {
        XCTAssertEqual(OpenRouterGateClient.outcome(for: URLError(.timedOut)), "timeout")
        XCTAssertEqual(OpenRouterGateClient.outcome(for: URLError(.cancelled)), "cancelled")
        XCTAssertEqual(OpenRouterGateClient.outcome(for: CancellationError()), "cancelled")
        XCTAssertEqual(OpenRouterGateClient.outcome(for: URLError(.notConnectedToInternet)), "network-error")
        struct Other: Error {}
        XCTAssertEqual(OpenRouterGateClient.outcome(for: Other()), "network-error")
    }

    // 9. transport safety
    func testNonHttpsRejected() async {
        let good = bad(confidence: 0.5)
        for u in ["http://example.invalid/x", "ftp://example.invalid/x", "file:///tmp/x"] {
            XCTAssertThrowsError(try OpenRouterGateClient.buildURLRequest(for: good, model: "m", apiKey: "k", endpoint: URL(string: u)!), u)
            let (res, rec) = await OpenRouterGateClient(apiKey: "k", model: "m", endpoint: URL(string: u)!).assess(good)
            XCTAssertEqual(res, .failure(.unavailable))
            XCTAssertEqual(rec.outcome, "request-error")
        }
        XCTAssertNoThrow(try OpenRouterGateClient.buildURLRequest(for: good, model: "m", apiKey: "k", endpoint: URL(string: "https://example.invalid/x")!))
    }

    func testRedirectsRefused() {
        let session = OpenRouterGateClient.makeSession()
        let from = URL(string: "https://example.invalid/a")!
        let task = session.dataTask(with: URLRequest(url: from))   // never resumed: no network
        let resp = HTTPURLResponse(url: from, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.invalid/b"])!
        var next = URLRequest(url: URL(string: "https://other.invalid/b")!)
        next.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        var called = false
        var result: URLRequest? = next
        NoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: resp, newRequest: next) { r in
            called = true; result = r
        }
        XCTAssertTrue(called)
        XCTAssertNil(result)
    }
}
