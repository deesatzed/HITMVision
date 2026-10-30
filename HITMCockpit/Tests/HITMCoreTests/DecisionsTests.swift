import XCTest
@testable import HITMCore

final class DecisionsTests: XCTestCase {
    private let questions = [
        DecisionsBooleanQuestion(id: "needs_human", instructions: "Should a human review this?",
                                 whenFalse: "No review needed.", whenTrue: "Review needed."),
        DecisionsBooleanQuestion(id: "hidden_risk", instructions: "Is there a hidden risk?",
                                 whenFalse: "No.", whenTrue: "Yes."),
    ]
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/alpha/decisions")!

    private func envelope(_ answers: String, usage: String = #"{"cost":0.00002,"input_tokens":476,"output_tokens":70}"#,
                          extra: String = #","model":"typesafe/jev-1.14-x","provider":"TypeSafe""#) -> Data {
        Data(#"{"answers":\#(answers),"usage":\#(usage)\#(extra)}"#.utf8)
    }

    // MARK: request

    func testDefaultEndpointIsTheMeasuredAlphaPath() {
        XCTAssertEqual(OpenRouterDecisionsTransport.defaultEndpoint.absoluteString,
                       "https://openrouter.ai/api/alpha/decisions")
    }

    func testRequestBodyShape() throws {
        let state = Data(#"{"actionClass":"routine","changeSize":3}"#.utf8)
        let req = try OpenRouterDecisionsTransport.buildURLRequest(
            model: "typesafe/jev-1.14", stateJSON: state, questions: questions, apiKey: "k", endpoint: endpoint)
        XCTAssertEqual(req.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "typesafe/jev-1.14")
        XCTAssertEqual((body["state"] as? [String: Any])?["changeSize"] as? Int, 3)
        let qs = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertEqual(Set(qs.keys), ["needs_human", "hidden_risk"])
        let q = try XCTUnwrap(qs["needs_human"] as? [String: Any])
        XCTAssertEqual(q["type"] as? String, "noul")
        XCTAssertEqual(q["instructions"] as? String, "Should a human review this?")
        let crit = try XCTUnwrap(q["criteria"] as? [String: String])
        XCTAssertEqual(crit["false"], "No review needed.")
        XCTAssertEqual(crit["true"], "Review needed.")
    }

    func testRequestNeverPutsKeyInBody() throws {
        let req = try OpenRouterDecisionsTransport.buildURLRequest(
            model: "m", stateJSON: Data("{}".utf8), questions: questions, apiKey: "SECRET-KEY-123", endpoint: endpoint)
        XCTAssertFalse(String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self).contains("SECRET-KEY-123"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer SECRET-KEY-123")
    }

    func testRejectsInsecureEndpoint() {
        XCTAssertThrowsError(try OpenRouterDecisionsTransport.buildURLRequest(
            model: "m", stateJSON: Data("{}".utf8), questions: questions, apiKey: "k",
            endpoint: URL(string: "http://openrouter.ai/api/v1/alpha/decisions")!))
    }

    func testRejectsStateThatIsNotJSON() {
        XCTAssertThrowsError(try OpenRouterDecisionsTransport.buildURLRequest(
            model: "m", stateJSON: Data("not json".utf8), questions: questions, apiKey: "k", endpoint: endpoint))
    }

    func testDescriptionNeverShowsKey() {
        let t = OpenRouterDecisionsTransport(apiKey: "SECRET-KEY-123", model: "m")
        XCTAssertFalse("\(t) \(String(reflecting: t))".contains("SECRET-KEY-123"))
        var dumped = ""; dump(t, to: &dumped)
        XCTAssertFalse(dumped.contains("SECRET-KEY-123"))
    }

    // MARK: response

    func testParsesNoulProbabilitiesAndUsage() {
        let data = envelope(#"{"needs_human":{"type":"noul","noul":0.96},"hidden_risk":{"type":"noul","noul":0.1}}"#)
        let (r, rec) = OpenRouterDecisionsTransport.parseEnvelope(data: data, statusCode: 200, latencyMs: 12, requestedModel: "typesafe/jev-1.14")
        XCTAssertEqual(r?.probabilities, ["needs_human": 0.96, "hidden_risk": 0.1])
        XCTAssertEqual(r?.provider, "TypeSafe")
        XCTAssertEqual(rec.outcome, "ok")
        XCTAssertEqual(rec.promptTokens, 476)
        XCTAssertEqual(rec.completionTokens, 70)
        XCTAssertEqual(rec.costUSD, 0.00002)
        XCTAssertEqual(rec.usedModel, "typesafe/jev-1.14-x")
    }

    func testHttpErrorGivesNoResult() {
        let (r, rec) = OpenRouterDecisionsTransport.parseEnvelope(data: Data("{}".utf8), statusCode: 402, latencyMs: 1, requestedModel: "m")
        XCTAssertNil(r)
        XCTAssertEqual(rec.outcome, "http-error")
        XCTAssertEqual(rec.httpStatus, 402)
    }

    func testNonJSONGivesInvalidResponse() {
        let (r, rec) = OpenRouterDecisionsTransport.parseEnvelope(data: Data("nope".utf8), statusCode: 200, latencyMs: 1, requestedModel: "m")
        XCTAssertNil(r)
        XCTAssertEqual(rec.outcome, "invalid-response")
    }

    func testOutOfRangeProbabilityIsInvalidForThatQuestionOnly() {
        let data = envelope(#"{"needs_human":{"type":"noul","noul":1.5},"hidden_risk":{"type":"noul","noul":0.2}}"#)
        let (r, _) = OpenRouterDecisionsTransport.parseEnvelope(data: data, statusCode: 200, latencyMs: 1, requestedModel: "m")
        XCTAssertEqual(r?.probabilities, ["hidden_risk": 0.2])
    }

    func testBooleanNaNAndStringValuesAreRejected() {
        let data = envelope(#"{"a":{"type":"noul","noul":true},"b":{"type":"noul","noul":"0.5"},"c":{"type":"noul"},"d":{"type":"noul","noul":0.5}}"#)
        let (r, _) = OpenRouterDecisionsTransport.parseEnvelope(data: data, statusCode: 200, latencyMs: 1, requestedModel: "m")
        XCTAssertEqual(r?.probabilities, ["d": 0.5])
    }

    func testNonNoulAnswersAreIgnored() {
        let data = envelope(#"{"x":{"type":"choice","choice":"a"},"y":{"type":"noul","noul":0.4}}"#)
        let (r, _) = OpenRouterDecisionsTransport.parseEnvelope(data: data, statusCode: 200, latencyMs: 1, requestedModel: "m")
        XCTAssertEqual(r?.probabilities, ["y": 0.4])
    }

    func testNoUsableAnswersIsInvalidResponse() {
        let (r, rec) = OpenRouterDecisionsTransport.parseEnvelope(
            data: envelope(#"{"x":{"type":"choice","choice":"a"}}"#), statusCode: 200, latencyMs: 1, requestedModel: "m")
        XCTAssertNil(r)
        XCTAssertEqual(rec.outcome, "invalid-response")
    }

    func testMissingAnswersKeyIsInvalidResponse() {
        let (r, rec) = OpenRouterDecisionsTransport.parseEnvelope(
            data: Data(#"{"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8), statusCode: 200, latencyMs: 1, requestedModel: "m")
        XCTAssertNil(r)
        XCTAssertEqual(rec.outcome, "invalid-response")
    }

    func testProviderIsSanitizedAndOptional() {
        let (r, _) = OpenRouterDecisionsTransport.parseEnvelope(
            data: envelope(#"{"y":{"type":"noul","noul":0.4}}"#, extra: ""), statusCode: 200, latencyMs: 1, requestedModel: "m")
        XCTAssertNil(r?.provider)
    }

    func testEnvironmentLookupFailsClosedOnBlankKey() {
        XCTAssertNil(OpenRouterDecisionsTransport.fromEnvironment(model: "m", environment: [:]))
        XCTAssertNil(OpenRouterDecisionsTransport.fromEnvironment(model: "m", environment: ["OPENROUTER_API_KEY": "  \n"]))
        XCTAssertNotNil(OpenRouterDecisionsTransport.fromEnvironment(model: "m", environment: ["OPENROUTER_API_KEY": "k"]))
    }
}
