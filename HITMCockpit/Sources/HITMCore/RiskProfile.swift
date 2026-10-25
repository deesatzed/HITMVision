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
    /// Sensitive projects never send intent text or summaries to any model. A missing key decodes as true.
    public let sensitive: Bool
    /// What callers must check: an unsure profile is treated as sensitive too.
    public var isSensitive: Bool { sensitive || unsure }

    public init(name: String, extraHumanRequired: Set<ActionClass>, unsure: Bool = false, sensitive: Bool = false) {
        self.name = name
        self.extraHumanRequired = extraHumanRequired
        self.unsure = unsure
        self.sensitive = sensitive
    }

    private enum CodingKeys: String, CodingKey { case name, extraHumanRequired, unsure, sensitive }

    /// A missing `unsure` key means the profile is not trustworthy: default to true (fail closed).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.extraHumanRequired = try c.decode(Set<ActionClass>.self, forKey: .extraHumanRequired)
        self.unsure = try c.decodeIfPresent(Bool.self, forKey: .unsure) ?? true
        self.sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? true
    }

    /// Any decode failure yields an unsure profile, never `.light`.
    public static func decodeOrStrict(_ data: Data) -> RiskProfile {
        (try? JSONDecoder().decode(RiskProfile.self, from: data))
            ?? RiskProfile(name: "undecodable", extraHumanRequired: [], unsure: true, sensitive: true)
    }

    public static let light = RiskProfile(name: "light", extraHumanRequired: [])
    public static let strict = RiskProfile(name: "strict",
        extraHumanRequired: [.editDomainLogic, .editSafetyCheck])
}
