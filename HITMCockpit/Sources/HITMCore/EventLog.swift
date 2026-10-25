import Foundation

public struct Event: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let revision: Int
    public let kind: String
    public let payload: String
    public let author: String
}

public struct EventLog: Sendable {
    public let sessionID: UUID
    public private(set) var events: [Event] = []

    public init(sessionID: UUID = UUID()) { self.sessionID = sessionID }

    @discardableResult
    public mutating func append(kind: String, payload: String, author: String) -> Event {
        let event = Event(sessionID: sessionID, revision: events.count + 1,
                          kind: kind, payload: payload, author: author)
        events.append(event)
        return event
    }

    /// Deletion is a recorded correction; the original event stays in the log.
    @discardableResult
    public mutating func correct(_ target: Event, reason: String, author: String) -> Event {
        append(kind: "correction", payload: "rev \(target.revision): \(reason)", author: author)
    }
}
