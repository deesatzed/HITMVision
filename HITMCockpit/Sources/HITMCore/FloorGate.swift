public enum FloorDecision: Equatable, Sendable {
    case humanRequired(reason: String)
    case noFloor
}

public enum FloorGate {
    public static let universalFloor: Set<ActionClass> = [.irreversible, .deploy, .externalSend]

    public static func evaluate(_ action: ActionClass, profile: RiskProfile) -> FloorDecision {
        switch action {
        case .irreversible, .deploy, .externalSend:
            return .humanRequired(reason: "Universal floor: \(action.rawValue)")
        case .editDomainLogic, .editSafetyCheck, .routine:
            let required = profile.extraHumanRequired.union(profile.unsure ? RiskProfile.strict.extraHumanRequired : [])
            return required.contains(action)
                ? .humanRequired(reason: "Profile '\(profile.name)' floor: \(action.rawValue)")
                : .noFloor
        }
    }

    /// The smart layer may add a human check, never remove one.
    public static func needsHuman(floor: FloorDecision, smartNeedsHuman: Bool) -> Bool {
        if case .humanRequired = floor { return true }
        return smartNeedsHuman
    }
}
