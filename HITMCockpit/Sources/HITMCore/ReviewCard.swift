import Foundation

public enum CardStatus: String, Codable, Sendable {
    case pending
    /// A named human passed it.
    case passed
    case rejected
    /// No human was needed; the work was kept on its branch and the card is only a record.
    case quietPassed
    /// A step failed before there was anything to review (nothing was changed).
    case failed
}

public struct CardStep: Codable, Equatable, Sendable {
    public let text: String
    public let claimedClass: ActionClass
    public let effectiveClass: ActionClass
}

/// One unit of work for the cockpit: what was asked, what changed (a real diff), why it did or did not reach a human.
public struct ReviewCard: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let intent: String
    public let title: String
    public let steps: [CardStep]
    /// Highest class from the plan, the implementer summary, the changed paths and every added line.
    public let overallClass: ActionClass
    public let branch: String?
    public let changedPaths: [String]
    public let diff: String
    public let diffTruncated: Bool
    public let addedLines: Int
    public let removedLines: Int
    public let needsHuman: Bool
    public let detailLevel: Int
    public let reasons: [String]
    public let gateFailed: Bool
    public let models: [String: String]
    public var status: CardStatus
    public var decidedBy: String?
    public var decidedAt: Date?

    public init(id: String, createdAt: Date = Date(), intent: String, title: String, steps: [CardStep], overallClass: ActionClass,
                branch: String?, changedPaths: [String], diff: String, diffTruncated: Bool, addedLines: Int, removedLines: Int,
                needsHuman: Bool, detailLevel: Int, reasons: [String], gateFailed: Bool, models: [String: String],
                status: CardStatus, decidedBy: String? = nil, decidedAt: Date? = nil) {
        self.id = id; self.createdAt = createdAt; self.intent = intent; self.title = title; self.steps = steps
        self.overallClass = overallClass; self.branch = branch; self.changedPaths = changedPaths; self.diff = diff
        self.diffTruncated = diffTruncated; self.addedLines = addedLines; self.removedLines = removedLines
        self.needsHuman = needsHuman; self.detailLevel = detailLevel; self.reasons = reasons; self.gateFailed = gateFailed
        self.models = models; self.status = status; self.decidedBy = decidedBy; self.decidedAt = decidedAt
    }
}

public enum InboxError: Error, Equatable, Sendable {
    case invalidID, notFound, alreadyDecided, humanNameRequired, notAHumanDecision, ioFailure
}

/// Cards as JSON files in one folder (`<repo>/.hitm/inbox`), plus an append-only `events.jsonl` of decisions.
/// The cockpit will read this same folder. A card is decided exactly once, and only by a named human.
public struct CardInbox: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private func url(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    public func write(_ card: ReviewCard) throws {
        guard Self.isValidID(card.id) else { throw InboxError.invalidID }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder().encode(card).write(to: url(card.id), options: .atomic)
        } catch { throw InboxError.ioFailure }
    }

    public func load(_ id: String) throws -> ReviewCard {
        guard Self.isValidID(id) else { throw InboxError.invalidID }
        guard let data = FileManager.default.contents(atPath: url(id).path) else { throw InboxError.notFound }
        guard let card = try? Self.decoder().decode(ReviewCard.self, from: data) else { throw InboxError.ioFailure }
        return card
    }

    /// Newest first. A file that does not decode is skipped here; `load` of that id still reports the failure.
    public func list() -> [ReviewCard] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder().decode(ReviewCard.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func decide(_ id: String, to status: CardStatus, by name: String, at now: Date = Date()) throws -> ReviewCard {
        guard status == .passed || status == .rejected else { throw InboxError.notAHumanDecision }
        let who = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { throw InboxError.humanNameRequired }
        var card = try load(id)
        guard card.status == .pending else { throw InboxError.alreadyDecided }
        card.status = status; card.decidedBy = who; card.decidedAt = now
        try write(card)
        try appendEvent(kind: status.rawValue, cardID: id, by: who, at: now)
        return card
    }

    public func appendEvent(kind: String, cardID: String, by: String, at: Date = Date()) throws {
        struct Ev: Codable { let kind: String; let cardID: String; let by: String; let at: Date }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        var line = try enc.encode(Ev(kind: kind, cardID: cardID, by: by, at: at)); line.append(0x0A)
        let file = directory.appendingPathComponent("events.jsonl")
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { guard fm.createFile(atPath: file.path, contents: nil) else { throw InboxError.ioFailure } }
        guard let h = try? FileHandle(forWritingTo: file) else { throw InboxError.ioFailure }
        defer { try? h.close() }
        do { try h.seekToEnd(); try h.write(contentsOf: line); try h.synchronize() } catch { throw InboxError.ioFailure }
    }
}
