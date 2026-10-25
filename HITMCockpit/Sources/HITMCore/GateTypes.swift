import Foundation

public enum GateRoute: String, Codable, Sendable {
    case proceed
    case askHuman = "ask_human"
    case escalateModel = "escalate_model"
}

public enum GateError: Error, Equatable, Sendable { case malformed, outOfRange, unavailable }

public struct GateRequest: Codable, Equatable, Sendable {
    public let actionClass: ActionClass
    public let profileName: String
    public let filePaths: [String]
    public let changeSize: Int
    /// nil = not reported; the key is omitted from the encoded JSON.
    public let agentConfidence: Double?
    public let overrideHistory: String
    /// nil for sensitive projects: metadata only. Omitted from the encoded JSON when nil.
    public let summary: String?

    public static func make(actionClass: ActionClass, profileName: String, filePaths: [String],
                            changeSize: Int, agentConfidence: Double?, overrideHistory: String,
                            summary: String?, profileSensitive: Bool) -> GateRequest {
        if profileSensitive {
            return GateRequest(actionClass: actionClass, profileName: "sensitive", filePaths: [],
                               changeSize: changeSize, agentConfidence: agentConfidence,
                               overrideHistory: "", summary: nil)
        }
        return GateRequest(actionClass: actionClass, profileName: profileName, filePaths: filePaths,
                           changeSize: changeSize, agentConfidence: agentConfidence,
                           overrideHistory: overrideHistory, summary: summary)
    }
}

public struct GateResponse: Codable, Equatable, Sendable {
    public let route: GateRoute
    public let needsHuman: Bool
    public let detailLevel: Int
    public let confidence: Double
    public let reason: String

    public static func decodeStrict(_ data: Data) -> Result<GateResponse, GateError> {
        guard let r = try? JSONDecoder().decode(GateResponse.self, from: data) else { return .failure(.malformed) }
        let clean = sanitize(r.reason)
        guard (0...3).contains(r.detailLevel), (0.0...1.0).contains(r.confidence), !clean.isEmpty
        else { return .failure(.outOfRange) }
        return .success(GateResponse(route: r.route, needsHuman: r.needsHuman, detailLevel: r.detailLevel,
                                     confidence: r.confidence, reason: clean))
    }

    /// Strip control (Cc) and format (Cf) characters, collapse whitespace, trim, cap at 300 characters.
    static func sanitize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars.prefix(2000) {
            if u.properties.isWhitespace { scalars.append(" "); continue }
            switch u.properties.generalCategory {
            case .control, .format: continue
            default: scalars.append(u)
            }
        }
        let collapsed = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let all = collapsed.unicodeScalars
        guard all.count > 300 else { return collapsed }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: all.prefix(300))
        return String(out) + "…"
    }
}

public struct GateDecision: Equatable, Sendable {
    public let needsHuman: Bool
    public let detailLevel: Int
    public let reasons: [String]
    public let gateFailed: Bool

    /// The floor always wins; the gate can only add a human check, never remove one.
    public static func combine(floor: FloorDecision, gate: Result<GateResponse, GateError>) -> GateDecision {
        var reasons: [String] = []
        var level = 0
        var smartNeeds = false
        var failed = false
        switch gate {
        case .failure:
            failed = true
            smartNeeds = true
            level = 2
            reasons.append("Gate unavailable or invalid, so it is asking you")
        case .success(let r):
            smartNeeds = r.needsHuman || r.route != .proceed
            level = min(3, max(0, r.detailLevel))
            reasons.append(r.reason)
        }
        if case .humanRequired(let reason) = floor {
            reasons.insert(reason, at: 0)
            level = max(level, 3)
        }
        return GateDecision(needsHuman: FloorGate.needsHuman(floor: floor, smartNeedsHuman: smartNeeds),
                            detailLevel: level, reasons: reasons, gateFailed: failed)
    }
}
