public enum ActionClass: String, Codable, CaseIterable, Sendable {
    case irreversible, deploy, externalSend
    case editDomainLogic, editSafetyCheck
    case routine
}

public struct RiskProfile: Codable, Equatable, Sendable {
    public let name: String
    public let extraHumanRequired: Set<ActionClass>
    /// If the profile could not be determined, the stricter profile applies.
    public let unsure: Bool

    public init(name: String, extraHumanRequired: Set<ActionClass>, unsure: Bool = false) {
        self.name = name
        self.extraHumanRequired = extraHumanRequired
        self.unsure = unsure
    }

    public static let light = RiskProfile(name: "light", extraHumanRequired: [])
    public static let strict = RiskProfile(name: "strict",
        extraHumanRequired: [.editDomainLogic, .editSafetyCheck])
}
