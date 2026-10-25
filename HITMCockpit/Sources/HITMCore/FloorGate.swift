public enum FloorDecision: Equatable, Sendable {
    case humanRequired(reason: String)
    case noFloor
}

public enum FloorGate {
    static let universal: Set<ActionClass> = [.irreversible, .deploy, .externalSend]

    public static func evaluate(_ action: ActionClass, profile: RiskProfile) -> FloorDecision {
        if universal.contains(action) {
            return .humanRequired(reason: "Universal floor: \(action.rawValue)")
        }
        let required = profile.extraHumanRequired.union(profile.unsure ? RiskProfile.strict.extraHumanRequired : [])
        if required.contains(action) {
            return .humanRequired(reason: "Profile '\(profile.name)' floor: \(action.rawValue)")
        }
        return .noFloor
    }

    /// The smart layer may add a human check, never remove one.
    public static func needsHuman(floor: FloorDecision, smartNeedsHuman: Bool) -> Bool {
        if case .humanRequired = floor { return true }
        return smartNeedsHuman
    }
}
