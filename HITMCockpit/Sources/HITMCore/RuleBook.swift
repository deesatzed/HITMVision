import Foundation

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Persisted values decode strictly: a key the type does not know is an error, not ignored.
private func rejectUnknownKeys(_ decoder: Decoder, known: Set<String>) throws {
    let c = try decoder.container(keyedBy: AnyKey.self)
    if let bad = c.allKeys.first(where: { !known.contains($0.stringValue) }) {
        throw DecodingError.dataCorruptedError(forKey: bad, in: c, debugDescription: "unknown key '\(bad.stringValue)'")
    }
}

/// Where a standing rule applies. `level` orders them narrow to wide (R3).
public enum RuleScope: Equatable, Sendable {
    case session(String)
    case projectFolder(String)
    case project
    case all

    public var level: ScopeLevel {
        switch self {
        case .session: return .session
        case .projectFolder: return .projectFolder
        case .project: return .project
        case .all: return .all
        }
    }
}

extension RuleScope: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }

    /// Strict: an unknown kind, or a session/folder without a non-empty value, fails to decode.
    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, known: ["kind", "value"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        func noValue() throws {
            if c.contains(.value) {
                throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "this scope takes no value")
            }
        }
        func value() throws -> String {
            let v = try c.decode(String.self, forKey: .value)
            guard !v.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "empty scope value")
            }
            return v
        }
        switch kind {
        case "session": self = .session(try value())
        case "projectFolder": self = .projectFolder(try value())
        case "project": try noValue(); self = .project
        case "all": try noValue(); self = .all
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown scope '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let id): try c.encode("session", forKey: .kind); try c.encode(id, forKey: .value)
        case .projectFolder(let p): try c.encode("projectFolder", forKey: .kind); try c.encode(p, forKey: .value)
        case .project: try c.encode("project", forKey: .kind)
        case .all: try c.encode("all", forKey: .kind)
        }
    }
}

public enum RuleEffect: String, Codable, Sendable {
    case allow, ask
}

/// A standing rule. It covers one exact command (argv[0]), optionally one exact subcommand (argv[1]),
/// inside one family. Persistence and approval come in the rule store; this is the value it will store.
public struct Rule: Codable, Equatable, Sendable {
    public let id: String
    public let family: CommandFamilyID
    public let command: String
    public let subcommand: String?
    public let scope: RuleScope
    public let effect: RuleEffect
    /// The project a project or folder rule belongs to. Without it those scopes never apply.
    public let projectID: String?
    /// For `.all` rules under strict, unsure or sensitive profiles: the projects where it was switched on.
    public let enabledForProjects: Set<String>
    public let expiresAt: Date?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, family, command, subcommand, scope, effect, projectID, enabledForProjects, expiresAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, known: Set(CodingKeys.allCases.map(\.stringValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.family = try c.decode(CommandFamilyID.self, forKey: .family)
        self.command = try c.decode(String.self, forKey: .command)
        self.subcommand = try c.decodeIfPresent(String.self, forKey: .subcommand)
        self.scope = try c.decode(RuleScope.self, forKey: .scope)
        self.effect = try c.decode(RuleEffect.self, forKey: .effect)
        self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        self.enabledForProjects = try c.decode(Set<String>.self, forKey: .enabledForProjects)
        self.expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    public init(id: String, family: CommandFamilyID, command: String, subcommand: String? = nil,
                scope: RuleScope, effect: RuleEffect, projectID: String? = nil,
                enabledForProjects: Set<String> = [], expiresAt: Date? = nil) {
        self.id = id; self.family = family; self.command = command; self.subcommand = subcommand
        self.scope = scope; self.effect = effect; self.projectID = projectID
        self.enabledForProjects = enabledForProjects; self.expiresAt = expiresAt
    }
}

public struct RuleContext: Equatable, Sendable {
    public let profile: RiskProfile
    /// From the classifier, supplied by the caller.
    public let actionClass: ActionClass
    public let projectID: String
    public let folderPath: String
    public let sessionID: String?

    public init(profile: RiskProfile, actionClass: ActionClass, projectID: String, folderPath: String, sessionID: String?) {
        self.profile = profile; self.actionClass = actionClass; self.projectID = projectID
        self.folderPath = folderPath; self.sessionID = sessionID
    }
}

public enum RuleDecision: Equatable, Sendable {
    case allow(ruleID: String)
    case ask(reason: String)
}

/// Deterministic decision: floor, then command shape, then standing rules. Never runs anything.
/// The caller must classify the action honestly: `context.actionClass` is trusted as given, and only the
/// floor (which runs first) decides above the rules. A class understated by the caller is not caught here.
public struct RuleBook: Sendable {
    public let rules: [Rule]
    /// Projects that have an onboarding record. Any other project is strict with no allow rules (R11).
    public let onboardedProjects: Set<String>
    /// Set by `RuleStore.ruleBook` when a standing-rule entry could not be verified or decoded. A rule that
    /// cannot be read might have been an ask rule, so nothing may be allowed until it is fixed.
    public let hasUnverifiedRules: Bool

    public init(rules: [Rule], onboardedProjects: Set<String>, hasUnverifiedRules: Bool = false) {
        self.rules = rules; self.onboardedProjects = onboardedProjects; self.hasUnverifiedRules = hasUnverifiedRules
    }
    public static let unverifiedReason = "A standing rule could not be verified, so everything asks until it is fixed"

    public func decide(command: String, context: RuleContext, now: Date = Date()) -> RuleDecision {
        // 1. The floor always wins; no rule is consulted.
        if case .humanRequired(let reason) = FloorGate.evaluate(context.actionClass, profile: context.profile) {
            return .ask(reason: "A person must decide this one (\(reason)). Standing rules never cover it.")
        }
        if hasUnverifiedRules { return .ask(reason: Self.unverifiedReason) }
        // 2. Only a plain command that is exactly in a known family can be covered.
        let argv: [String]
        switch CommandParser.parse(command) {
        case .notSimple(let why):
            return .ask(reason: "This is not a plain single command (it \(why)), so no standing rule covers it.")
        case .simple(let a): argv = a
        }
        let family: CommandFamilyID
        switch CommandFamilies.match(argv: argv) {
        case .unknown(let why):
            return .ask(reason: "No standing rule can cover this command: \(why).")
        case .matched(let id): family = id
        }
        if !onboardedProjects.contains(context.projectID) {
            return .ask(reason: "This project has no rules set up yet, so it is treated as strict and asks every time.")
        }

        // 3. Rules for this command shape whose scope fits and that have not expired.
        let ceiling = CommandFamilies.family(family).ceiling
        let strictLike = Self.isStrictLike(context.profile)
        // Subcommand words, not argv[1]: `xcodebuild -scheme X test` has its action word elsewhere. An ask rule fires
        // if any word matches; an allow rule needs every word to be its subcommand.
        let words = CommandFamilies.subcommandWords(argv: argv)
        func subcommandFits(_ r: Rule) -> Bool {
            guard let sub = r.subcommand else { return true }
            return r.effect == .ask ? words.contains { $0.sSame(sub) } : (!words.isEmpty && words.allSatisfy { $0.sSame(sub) })
        }
        let shaped = rules.filter { r in
            r.family == family && r.command == argv[0] && subcommandFits(r)
                && !(r.expiresAt.map { $0 <= now } ?? false)
                && Self.scopeMatches(r, context)
        }
        // 4. An ask rule wins over every allow. Ceiling and `.all` gating only limit allow rules: a stricter
        //    rule is never ignored for being too wide.
        if let ask = shaped.filter({ $0.effect == .ask }).min(by: { $0.id < $1.id }) {
            return .ask(reason: "Your standing rule '\(ask.id)' says to always ask for this kind of command.")
        }
        // 5. Narrowest applicable allow wins; ties go to the smallest id so the result is stable.
        let allows = shaped.filter { r in
            guard r.effect == .allow, r.scope.level <= ceiling else { return false }
            if r.scope.level == .all && strictLike && !r.enabledForProjects.contains(context.projectID) { return false }
            if case .projectFolder = r.scope, Self.leavesFolder(argv) { return false }
            return true
        }
        if let best = allows.min(by: { ($0.scope.level, $0.id) < ($1.scope.level, $1.id) }) {
            return .allow(ruleID: best.id)
        }
        // 6. No rule covers it.
        return .ask(reason: "No standing rule covers this command, so a person decides.")
    }

    /// Strict, unsure or sensitive, decided only through the floor gate and `isSensitive`: a profile that
    /// would force a human onto any non-universal class is strict-like. Names are never read.
    static func isStrictLike(_ profile: RiskProfile) -> Bool {
        if profile.isSensitive { return true }
        for action in [ActionClass.editDomainLogic, .editSafetyCheck, .routine] {
            if case .humanRequired = FloorGate.evaluate(action, profile: profile) { return true }
        }
        return false
    }

    static func scopeMatches(_ rule: Rule, _ c: RuleContext) -> Bool {
        switch rule.scope {
        case .all: return true
        case .project: return rule.projectID == c.projectID
        case .session(let id): return c.sessionID == id
        case .projectFolder(let folder):
            guard rule.projectID == c.projectID,
                  let ruleParts = normalizedComponents(folder), !ruleParts.isEmpty,
                  let ctxParts = normalizedComponents(c.folderPath) else { return false }
            return ctxParts.starts(with: ruleParts)
        }
    }

    /// Absolute path split into components with empty and `.` parts dropped. Relative paths, empty paths,
    /// NUL, and any `..` segment are rejected (nil) rather than resolved. Symlinks are not followed.
    static func normalizedComponents(_ path: String) -> [String]? {
        guard path.sHasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        var parts: [String] = []
        for seg in path.sSplit(["/"]) {       // scalars, so "/" followed by a combining mark still separates
            if seg.sSame("..") { return nil }
            if !seg.sSame(".") { parts.append(seg) }
        }
        return parts
    }

    /// True if any argument, a flag's `=value`, or text attached to a short flag (`-f/etc/hosts`, `-n../x`) is an
    /// absolute path or has a `..` component: such a command can read outside the folder a folder-scoped
    /// rule is limited to. Over-asks on patterns that look like paths.
    static func leavesFolder(_ argv: [String]) -> Bool {
        argv.dropFirst().contains { CommandFamilies.pathCandidates($0).contains { CommandFamilies.pathLeavesTree($0) } }
    }
}
