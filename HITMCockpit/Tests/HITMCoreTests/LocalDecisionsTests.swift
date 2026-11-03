import XCTest
@testable import HITMCore

final class LocalDecisionsTests: XCTestCase {
    private let q = DecisionsBooleanQuestion(id: "needs_human", instructions: "Review?", whenFalse: "No.", whenTrue: "Yes.")
    private let state = Data(#"{"actionClass":"routine"}"#.utf8)

    func testOnlyLoopbackEndpointsAreAccepted() {
        for ok in ["http://127.0.0.1:8000/v1/decide", "http://localhost:9000/v1/decide", "http://[::1]:8000/v1/decide"] {
            XCTAssertNotNil(LocalDecisionsTransport(model: "m", endpoint: URL(string: ok)!), ok)
        }
        for bad in ["https://openrouter.ai/v1/decide", "http://192.168.1.5:8000/v1/decide", "http://127.0.0.1.evil.com/v1/decide",
                    "http://0.0.0.0:8000/v1/decide", "ftp://127.0.0.1/x", "file:///tmp/x"] {
            XCTAssertNil(LocalDecisionsTransport(model: "m", endpoint: URL(string: bad)!), bad)
        }
    }

    func testDefaultEndpointIsLoopback() {
        XCTAssertTrue(LocalDecisionsTransport.isLoopback(LocalDecisionsTransport.defaultEndpoint))
    }

    func testRequestBodyCarriesOneNoulQuestionAndNoAuthHeader() throws {
        let req = try LocalDecisionsTransport.buildURLRequest(stateJSON: state, question: q, endpoint: LocalDecisionsTransport.defaultEndpoint)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual((body["state"] as? [String: Any])?["actionClass"] as? String, "routine")
        let qq = try XCTUnwrap(body["question"] as? [String: Any])
        XCTAssertEqual(qq["type"] as? String, "noul")
        XCTAssertEqual((qq["criteria"] as? [String: String])?["true"], "Yes.")
    }

    func testBuildRefusesNonLoopbackEndpoint() {
        XCTAssertThrowsError(try LocalDecisionsTransport.buildURLRequest(
            stateJSON: state, question: q, endpoint: URL(string: "https://openrouter.ai/x")!))
    }

    func testRejectsStateThatIsNotJSON() {
        XCTAssertThrowsError(try LocalDecisionsTransport.buildURLRequest(
            stateJSON: Data("nope".utf8), question: q, endpoint: LocalDecisionsTransport.defaultEndpoint))
    }

    func testParsesProbabilityOfTrue() {
        let d = Data(#"{"options":["false","true"],"probabilities":[0.2,0.8],"choice":"true","choice_index":1}"#.utf8)
        XCTAssertEqual(LocalDecisionsTransport.parseProbability(data: d), 0.8)
    }

    func testRejectsMalformedAnswers() {
        for s in [#"{"options":["true","false"],"probabilities":[0.2,0.8]}"#,
                  #"{"options":["false","true"],"probabilities":[0.2]}"#,
                  #"{"options":["false","true"],"probabilities":[0.2,1.5]}"#,
                  #"{"options":["false","true"],"probabilities":[true,false]}"#,
                  #"{"probabilities":[0.2,0.8]}"#, "nope"] {
            XCTAssertNil(LocalDecisionsTransport.parseProbability(data: Data(s.utf8)), s)
        }
    }

    func testUnreachableServerFailsClosedWithNoResult() async throws {
        // Port 1 on loopback has no listener: the call must yield no result (the caller then asks a human).
        let t = try XCTUnwrap(LocalDecisionsTransport(model: "m", endpoint: URL(string: "http://127.0.0.1:1/v1/decide")!))
        let (r, rec) = await t.assess(stateJSON: state, questions: [q])
        XCTAssertNil(r)
        XCTAssertNotEqual(rec.outcome, "ok")
    }
}
