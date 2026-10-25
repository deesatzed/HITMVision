import Foundation

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

    private enum CodingKeys: String, CodingKey { case name, extraHumanRequired, unsure }

    /// A missing `unsure` key means the profile is not trustworthy: default to true (fail closed).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.extraHumanRequired = try c.decode(Set<ActionClass>.self, forKey: .extraHumanRequired)
        self.unsure = try c.decodeIfPresent(Bool.self, forKey: .unsure) ?? true
    }

    /// Any decode failure yields an unsure profile, never `.light`.
    public static func decodeOrStrict(_ data: Data) -> RiskProfile {
        (try? JSONDecoder().decode(RiskProfile.self, from: data))
            ?? RiskProfile(name: "undecodable", extraHumanRequired: [], unsure: true)
    }

    public static let light = RiskProfile(name: "light", extraHumanRequired: [])
    public static let strict = RiskProfile(name: "strict",
        extraHumanRequired: [.editDomainLogic, .editSafetyCheck])
}
