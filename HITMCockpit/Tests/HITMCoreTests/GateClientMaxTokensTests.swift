import XCTest
@testable import HITMCore

final class GateClientMaxTokensTests: XCTestCase {
    func testLiveDefaultStaysAt400() {
        XCTAssertEqual(OpenRouterGateClient.maxTokens, 400)
    }

    func testCallerCanRaiseTheLimitWithoutChangingTheDefault() {
        XCTAssertNotNil(OpenRouterGateClient.fromEnvironment(model: "m", environment: ["OPENROUTER_API_KEY": "k"], maxTokens: 2000))
        XCTAssertNotNil(OpenRouterGateClient.fromEnvironment(model: "m", environment: ["OPENROUTER_API_KEY": "k"]))
        XCTAssertNil(OpenRouterGateClient.fromEnvironment(model: "m", environment: [:], maxTokens: 2000))
    }

    func testRequestBodyCarriesTheCallersLimit() throws {
        let req = try OpenRouterTransport.buildURLRequest(
            messages: [ChatMessage(role: "user", content: "x")], schemaName: "s",
            schemaJSON: Data(#"{"type":"object"}"#.utf8), maxTokens: 2000, model: "m", apiKey: "k",
            endpoint: OpenRouterTransport.defaultEndpoint)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 2000)
    }
}
