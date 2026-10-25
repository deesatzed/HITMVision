import XCTest
@testable import HITMCore

final class RiskProfileTests: XCTestCase {
    private func isHuman(_ d: FloorDecision) -> Bool {
        if case .humanRequired = d { return true }
        return false
    }

    private func assertStrictlyGated(_ p: RiskProfile, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(p.unsure, file: file, line: line)
        for a in [ActionClass.editDomainLogic, .editSafetyCheck] {
            XCTAssertTrue(isHuman(FloorGate.evaluate(a, profile: p)), "\(a)", file: file, line: line)
        }
    }

    func testMissingUnsureKeyDecodesAsUnsure() throws {
        let data = Data(#"{"name":"x","extraHumanRequired":[]}"#.utf8)
        let p = try JSONDecoder().decode(RiskProfile.self, from: data)
        XCTAssertTrue(p.unsure)
        assertStrictlyGated(p)
    }

    func testGarbageDataYieldsUnsureProfile() {
        let p = RiskProfile.decodeOrStrict(Data("not json at all".utf8))
        XCTAssertEqual(p.name, "undecodable")
        assertStrictlyGated(p)
    }

    func testUnknownActionClassYieldsUnsureProfile() {
        let data = Data(#"{"name":"x","extraHumanRequired":["bogusAction"],"unsure":false}"#.utf8)
        let p = RiskProfile.decodeOrStrict(data)
        XCTAssertEqual(p.name, "undecodable")
        assertStrictlyGated(p)
    }

    func testValidProfileRoundTripsUnchangedAndStaysNotUnsure() throws {
        let original = RiskProfile(name: "custom", extraHumanRequired: [.editDomainLogic], unsure: false)
        let data = try JSONEncoder().encode(original)
        let decoded = RiskProfile.decodeOrStrict(data)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.unsure)
        XCTAssertEqual(RiskProfile.decodeOrStrict(try JSONEncoder().encode(RiskProfile.light)), .light)
    }
}
