import Foundation

/// How often a standing rule has auto-allowed something, for the "standing rules" view (R9).
public struct RuleUsage: Codable, Equatable, Sendable {
    public var count: Int
    public var lastUsed: Date?
    /// A sane ceiling, so a corrupted file cannot make `count += 1` trap.
    public static let maxCount = 1_000_000_000

    public init(count: Int = 0, lastUsed: Date? = nil) { self.count = count; self.lastUsed = lastUsed }

    private enum CodingKeys: String, CodingKey { case count, lastUsed }

    /// Strict: a negative or absurd count fails to decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = try c.decode(Int.self, forKey: .count)
        guard (0...Self.maxCount).contains(n) else {
            throw DecodingError.dataCorruptedError(forKey: .count, in: c, debugDescription: "count out of range")
        }
        self.count = n
        self.lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
    }
}

/// A plain value the caller keeps and updates. `record` counts only an allow; an ask changes nothing.
public struct RuleUsageLog: Codable, Equatable, Sendable {
    public private(set) var byRule: [String: RuleUsage] = [:]
    public init() {}

    public func usage(for ruleID: String) -> RuleUsage { byRule[ruleID] ?? RuleUsage() }

    public mutating func record(_ decision: RuleDecision, at date: Date) {
        guard case .allow(let id) = decision else { return }
        var u = usage(for: id)
        u.count = min(u.count + 1, RuleUsage.maxCount)
        u.lastUsed = date
        byRule[id] = u
    }
}

extension RuleBook {
    /// Plain-language account of a decision, for the card's "how this was worked out".
    public func explanation(for decision: RuleDecision) -> String {
        switch decision {
        case .ask(let reason):
            return "A person needs to decide this. \(reason)"
        case .allow(let id):
            guard let r = rules.first(where: { $0.id == id }) else {
                return "Allowed by standing rule '\(id)'. The safety floor was checked first and did not require a person."
            }
            let what = [r.command, r.subcommand].compactMap { $0 }.joined(separator: " ")
            return "Allowed without asking by your standing rule '\(id)' for '\(what)', which covers \(Self.describe(r.scope)). "
                + "The safety floor was checked first and did not require a person."
        }
    }

    private static func describe(_ scope: RuleScope) -> String {
        switch scope {
        case .session: return "this session only"
        case .projectFolder(let path): return "the folder \(path)"
        case .project: return "this project"
        case .all: return "all projects"
        }
    }
}
