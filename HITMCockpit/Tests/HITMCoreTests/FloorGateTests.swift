import XCTest
@testable import HITMCore

final class FloorGateTests: XCTestCase {
    private func isHuman(_ d: FloorDecision) -> Bool {
        if case .humanRequired = d { return true }
        return false
    }

    private let universalActions: [ActionClass] = [.irreversible, .deploy, .externalSend]

    func testLightProfileLetsRoutineWorkProceed() {
        XCTAssertEqual(FloorGate.evaluate(.routine, profile: .light), .noFloor)
    }

    func testUniversalFloorAppliesToEveryProfile() {
        let emptyCustom = RiskProfile(name: "custom", extraHumanRequired: [])
        let unsureEmpty = RiskProfile(name: "unsure", extraHumanRequired: [], unsure: true)
        for profile in [RiskProfile.light, .strict, emptyCustom, unsureEmpty] {
            for action in universalActions {
                XCTAssertTrue(isHuman(FloorGate.evaluate(action, profile: profile)),
                              "\(action) must need a human under \(profile.name)")
            }
        }
    }

    func testStrictProfileAddsDomainLogicAndSafetyCheckEdits() {
        for action in [ActionClass.editDomainLogic, .editSafetyCheck] {
            XCTAssertTrue(isHuman(FloorGate.evaluate(action, profile: .strict)))
            XCTAssertEqual(FloorGate.evaluate(action, profile: .light), .noFloor)
        }
    }

    func testUnsureProfileIsTreatedAsStrict() {
        let unsure = RiskProfile(name: "unsure", extraHumanRequired: [], unsure: true)
        XCTAssertTrue(isHuman(FloorGate.evaluate(.editDomainLogic, profile: unsure)))
        XCTAssertTrue(isHuman(FloorGate.evaluate(.editSafetyCheck, profile: unsure)))
        XCTAssertEqual(FloorGate.evaluate(.routine, profile: unsure), .noFloor)
        XCTAssertEqual(FloorGate.evaluate(.routine, profile: .strict), .noFloor)
    }

    func testUnsureProfileKeepsItsOwnExtrasAndAddsStrict() {
        let unsure = RiskProfile(name: "u", extraHumanRequired: [.routine], unsure: true)
        for action in [ActionClass.routine, .editDomainLogic, .editSafetyCheck] {
            XCTAssertTrue(isHuman(FloorGate.evaluate(action, profile: unsure)),
                          "\(action) must need a human for an unsure profile")
        }
    }

    func testSmartLayerCanAddButNeverRemoveHuman() {
        let floor = FloorGate.evaluate(.deploy, profile: .light)
        XCTAssertTrue(FloorGate.needsHuman(floor: floor, smartNeedsHuman: false))
        XCTAssertTrue(FloorGate.needsHuman(floor: .noFloor, smartNeedsHuman: true))
        XCTAssertFalse(FloorGate.needsHuman(floor: .noFloor, smartNeedsHuman: false))
    }

    func testExpectedFloorTableCoversEveryActionClass() {
        let light: [ActionClass: Bool] = [
            .irreversible: true, .deploy: true, .externalSend: true,
            .editDomainLogic: false, .editSafetyCheck: false, .routine: false,
        ]
        let strict: [ActionClass: Bool] = [
            .irreversible: true, .deploy: true, .externalSend: true,
            .editDomainLogic: true, .editSafetyCheck: true, .routine: false,
        ]
        for (name, profile, table) in [("light", RiskProfile.light, light),
                                       ("strict", RiskProfile.strict, strict)] {
            for action in ActionClass.allCases {
                guard let expected = table[action] else {
                    XCTFail("\(action) is not classified in the \(name) table")
                    continue
                }
                XCTAssertEqual(isHuman(FloorGate.evaluate(action, profile: profile)), expected,
                               "\(action) under \(name)")
            }
        }
    }

    func testEveryHumanRequiredDecisionCarriesAReason() {
        let expected: Set<ActionClass> = [.irreversible, .deploy, .externalSend,
                                          .editDomainLogic, .editSafetyCheck]
        var seen: Set<ActionClass> = []
        for action in ActionClass.allCases {
            if case .humanRequired(let reason) = FloorGate.evaluate(action, profile: .strict) {
                XCTAssertFalse(reason.isEmpty, "\(action) has an empty reason")
                seen.insert(action)
            }
        }
        XCTAssertTrue(expected.isSubset(of: seen), "missing human-required: \(expected.subtracting(seen))")
    }
}
