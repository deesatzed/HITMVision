import XCTest
@testable import HITMCore

final class GateTypesTests: XCTestCase {
    private func request(sensitive: Bool) -> GateRequest {
        GateRequest.make(actionClass: .routine, profileName: "light", filePaths: ["a.swift"],
                         changeSize: 3, agentConfidence: 0.8, overrideHistory: "none",
                         summary: "rename a variable", profileSensitive: sensitive)
    }

    private func keys(_ r: GateRequest) throws -> Set<String> {
        let data = try JSONEncoder().encode(r)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return Set(obj.keys)
    }

    func testSensitiveRequestOmitsSummaryKey() throws {
        let r = request(sensitive: true)
        XCTAssertNil(r.summary)
        XCTAssertFalse(try keys(r).contains("summary"))
        let json = String(data: try JSONEncoder().encode(r), encoding: .utf8)!
        XCTAssertFalse(json.contains("summary"))
    }

    func testNonSensitiveRequestIncludesSummary() throws {
        let r = request(sensitive: false)
        XCTAssertEqual(r.summary, "rename a variable")
        XCTAssertTrue(try keys(r).contains("summary"))
    }

    func testRequestKeySetHasNoFileContents() throws {
        XCTAssertEqual(try keys(request(sensitive: false)),
            ["actionClass", "profileName", "filePaths", "changeSize",
             "agentConfidence", "overrideHistory", "summary"])
        XCTAssertEqual(try keys(request(sensitive: true)),
            ["actionClass", "profileName", "filePaths", "changeSize",
             "agentConfidence", "overrideHistory"])
    }

    // MARK: decodeStrict

    private func decode(_ s: String) -> Result<GateResponse, GateError> {
        GateResponse.decodeStrict(Data(s.utf8))
    }

    private func json(route: String = "\"proceed\"", needs: String = "false", level: String = "1",
                      conf: String = "0.9", reason: String = "\"ok\"") -> String {
        "{\"route\":\(route),\"needsHuman\":\(needs),\"detailLevel\":\(level),\"confidence\":\(conf),\"reason\":\(reason)}"
    }

    func testDecodeStrictAcceptsValid() {
        let r = decode(json())
        XCTAssertEqual(r, .success(GateResponse(route: .proceed, needsHuman: false,
                                                detailLevel: 1, confidence: 0.9, reason: "ok")))
        XCTAssertEqual(decode(json(route: "\"ask_human\"")).map(\.route), .success(.askHuman))
        XCTAssertEqual(decode(json(route: "\"escalate_model\"")).map(\.route), .success(.escalateModel))
    }

    func testDecodeStrictRejectsMalformed() {
        XCTAssertEqual(decode("not json"), .failure(.malformed))
        XCTAssertEqual(decode("{\"route\":\"proceed\",\"needsHuman\":false,\"detailLevel\":1,\"confidence\":0.9}"),
                       .failure(.malformed))
        XCTAssertEqual(decode(json(needs: "\"no\"")), .failure(.malformed))
        XCTAssertEqual(decode(json(level: "\"2\"")), .failure(.malformed))
        XCTAssertEqual(decode(json(route: "\"teleport\"")), .failure(.malformed))
    }

    func testDecodeStrictRejectsOutOfRange() {
        for level in ["4", "-1"] { XCTAssertEqual(decode(json(level: level)), .failure(.outOfRange), level) }
        for conf in ["1.5", "-0.1"] { XCTAssertEqual(decode(json(conf: conf)), .failure(.outOfRange), conf) }
        XCTAssertEqual(decode(json(reason: "\"\"")), .failure(.outOfRange))
        XCTAssertEqual(decode(json(reason: "\"  \\n \"")), .failure(.outOfRange))
    }

    // MARK: combine

    private func resp(_ route: GateRoute, _ needs: Bool, level: Int = 1) -> Result<GateResponse, GateError> {
        .success(GateResponse(route: route, needsHuman: needs, detailLevel: level, confidence: 0.9, reason: "r"))
    }
    private let floorHuman = FloorDecision.humanRequired(reason: "Universal floor: deploy")

    func testFloorWinsOverQuietGate() {
        let d = GateDecision.combine(floor: floorHuman, gate: resp(.proceed, false, level: 0))
        XCTAssertTrue(d.needsHuman)
        XCTAssertFalse(d.gateFailed)
        XCTAssertTrue(d.reasons.contains("Universal floor: deploy"))
        XCTAssertGreaterThanOrEqual(d.detailLevel, 3)
    }

    func testGateFailureWithNoFloorAsksHuman() {
        for err in [GateError.malformed, .outOfRange] {
            let d = GateDecision.combine(floor: .noFloor, gate: .failure(err))
            XCTAssertTrue(d.needsHuman)
            XCTAssertTrue(d.gateFailed)
            XCTAssertEqual(d.detailLevel, 2)
            XCTAssertTrue(d.reasons.contains { $0.contains("Gate unavailable or invalid, so it is asking you") })
        }
    }

    func testCleanPassThrough() {
        let d = GateDecision.combine(floor: .noFloor, gate: resp(.proceed, false, level: 1))
        XCTAssertFalse(d.needsHuman)
        XCTAssertFalse(d.gateFailed)
        XCTAssertEqual(d.detailLevel, 1)
    }

    func testGateCanAddHuman() {
        XCTAssertTrue(GateDecision.combine(floor: .noFloor, gate: resp(.proceed, true)).needsHuman)
    }

    func testInconsistentAnswersResolveToHuman() {
        XCTAssertTrue(GateDecision.combine(floor: .noFloor, gate: resp(.proceed, true)).needsHuman)
        XCTAssertTrue(GateDecision.combine(floor: .noFloor, gate: resp(.askHuman, false)).needsHuman)
        XCTAssertTrue(GateDecision.combine(floor: .noFloor, gate: resp(.escalateModel, false)).needsHuman)
    }

    func testDetailLevelClamped() {
        let d = GateDecision.combine(floor: .noFloor, gate: resp(.proceed, false, level: 9))
        XCTAssertEqual(d.detailLevel, 3)
        let e = GateDecision.combine(floor: .noFloor, gate: resp(.proceed, false, level: -4))
        XCTAssertEqual(e.detailLevel, 0)
    }

    func testCombineNeverDropsFloorForEveryClassAndProfile() {
        let profiles = [RiskProfile.light, .strict, RiskProfile(name: "u", extraHumanRequired: [], unsure: true)]
        let gates: [Result<GateResponse, GateError>] = [resp(.proceed, false, level: 0), .failure(.malformed)]
        for action in ActionClass.allCases {
            for profile in profiles {
                let floor = FloorGate.evaluate(action, profile: profile)
                for gate in gates {
                    let d = GateDecision.combine(floor: floor, gate: gate)
                    if case .humanRequired = floor {
                        XCTAssertTrue(d.needsHuman, "\(action) \(profile.name)")
                        XCTAssertGreaterThanOrEqual(d.detailLevel, 3)
                    }
                }
            }
        }
    }
}

final class GateTypesHardeningTests: XCTestCase {
    private func encoded(sensitive: Bool) throws -> String {
        let r = GateRequest.make(actionClass: .routine, profileName: "JD-genome-project",
            filePaths: ["patients/JD_sample_0042.vcf"], changeSize: 7, agentConfidence: 0.6,
            overrideHistory: "rejected the JD change", summary: "JD sample analysis", profileSensitive: sensitive)
        return String(data: try JSONEncoder().encode(r), encoding: .utf8)!
    }
    private let identifying = ["JD_sample_0042", "rejected the JD change", "JD-genome-project", "JD sample analysis", "JD"]

    func testSensitiveRequestSendsMetadataOnly() throws {
        let s = try encoded(sensitive: true)
        for needle in identifying { XCTAssertFalse(s.contains(needle), needle) }
        let r = GateRequest.make(actionClass: .deploy, profileName: "x", filePaths: ["a"], changeSize: 7,
            agentConfidence: 0.6, overrideHistory: "h", summary: "s", profileSensitive: true)
        XCTAssertEqual(r.filePaths, [])
        XCTAssertEqual(r.overrideHistory, "")
        XCTAssertEqual(r.profileName, "sensitive")
        XCTAssertEqual(r.changeSize, 7)
        XCTAssertEqual(r.agentConfidence, 0.6)
        XCTAssertEqual(r.actionClass, .deploy)
    }

    func testNonSensitiveRequestStillCarriesValues() throws {
        let s = try encoded(sensitive: false)
        for needle in identifying { XCTAssertTrue(s.contains(needle), needle) }
    }

    private func decode(_ s: String) -> Result<GateResponse, GateError> { GateResponse.decodeStrict(Data(s.utf8)) }
    private func json(level: String = "1", conf: String = "0.9", reasonJSON: String = "\"ok\"") -> String {
        "{\"route\":\"proceed\",\"needsHuman\":false,\"detailLevel\":\(level),\"confidence\":\(conf),\"reason\":\(reasonJSON)}"
    }
    private func reason(_ raw: String) -> Result<String, GateError> {
        let data = try! JSONSerialization.data(withJSONObject: ["route": "proceed", "needsHuman": false,
            "detailLevel": 1, "confidence": 0.5, "reason": raw])
        return GateResponse.decodeStrict(data).map(\.reason)
    }

    func testReasonSanitizing() {
        XCTAssertEqual(reason("a\n\n b\t\tc  d"), .success("a b c d"))
        XCTAssertEqual(reason("x\u{202E}y\u{200B}z"), .success("xyz"))
        XCTAssertEqual(reason("\u{200B}"), .failure(.outOfRange))
        XCTAssertEqual(reason(" \u{200B} \n"), .failure(.outOfRange))
        XCTAssertEqual(reason("Looks fine."), .success("Looks fine."))
        if case .success(let s) = reason(String(repeating: "a", count: 10_000)) {
            XCTAssertLessThanOrEqual(s.count, 301)
            XCTAssertTrue(s.hasSuffix("…"))
        } else { XCTFail("expected success") }
    }

    func testBoundariesAccepted() {
        for l in ["0", "3"] { XCTAssertNotNil(try? decode(json(level: l)).get(), l) }
        for c in ["0.0", "1.0"] { XCTAssertNotNil(try? decode(json(conf: c)).get(), c) }
    }

    func testWrongTypesRejected() {
        XCTAssertEqual(decode(json(level: "1.5")), .failure(.malformed))
        XCTAssertEqual(decode(json(level: "true")), .failure(.malformed))
        XCTAssertEqual(decode(json(conf: "\"0.5\"")), .failure(.malformed))
    }

    private func resp(_ route: GateRoute, level: Int) -> Result<GateResponse, GateError> {
        .success(GateResponse(route: route, needsHuman: false, detailLevel: level, confidence: 0.9, reason: "r"))
    }

    func testUnavailableAndMalformedBothFail() {
        for e in [GateError.unavailable, .malformed] {
            let d = GateDecision.combine(floor: .noFloor, gate: .failure(e))
            XCTAssertTrue(d.needsHuman); XCTAssertTrue(d.gateFailed)
        }
    }

    func testFloorWithEscalateAndWithFailure() {
        let floor = FloorDecision.humanRequired(reason: "F")
        let a = GateDecision.combine(floor: floor, gate: resp(.escalateModel, level: 3))
        XCTAssertTrue(a.needsHuman); XCTAssertGreaterThanOrEqual(a.detailLevel, 3)
        let b = GateDecision.combine(floor: floor, gate: .failure(.unavailable))
        XCTAssertTrue(b.gateFailed); XCTAssertTrue(b.needsHuman)
    }

    func testTableIncludesEscalate() {
        let profiles = [RiskProfile.light, .strict, RiskProfile(name: "u", extraHumanRequired: [], unsure: true)]
        let gates: [Result<GateResponse, GateError>] = [resp(.proceed, level: 0), resp(.escalateModel, level: 0),
            .failure(.malformed), .failure(.unavailable)]
        for action in ActionClass.allCases { for p in profiles {
            let floor = FloorGate.evaluate(action, profile: p)
            guard case .humanRequired = floor else { continue }
            for g in gates {
                let d = GateDecision.combine(floor: floor, gate: g)
                XCTAssertTrue(d.needsHuman); XCTAssertGreaterThanOrEqual(d.detailLevel, 3)
            }
        } }
    }
}

final class GateReasonCapTests: XCTestCase {
    private func reason(_ raw: String) -> String? {
        let data = try! JSONSerialization.data(withJSONObject: ["route": "proceed", "needsHuman": false,
            "detailLevel": 1, "confidence": 0.5, "reason": raw])
        return try? GateResponse.decodeStrict(data).get().reason
    }

    func testCombiningMarksCappedByScalars() {
        let r = reason("a" + String(repeating: "\u{0301}", count: 100_000))!
        XCTAssertLessThanOrEqual(r.unicodeScalars.count, 301)
    }

    func testExactCapBoundaries() {
        XCTAssertEqual(reason(String(repeating: "a", count: 301)), String(repeating: "a", count: 300) + "…")
        XCTAssertEqual(reason(String(repeating: "a", count: 300)), String(repeating: "a", count: 300))
    }

    func testHugeReasonIsCappedQuickly() {
        let start = Date()
        let r = reason(String(repeating: "x", count: 1_000_000))!
        XCTAssertLessThanOrEqual(r.unicodeScalars.count, 301)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
