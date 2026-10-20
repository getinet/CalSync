import Foundation

/// A concrete, timed event read from one of the two source calendars.
/// All-day events never become instances — they are filtered out at read time.
public struct SourceInstance: Equatable, Sendable {
    public let uid: String
    public let start: Date
    public let end: Date
    public let isRecurring: Bool
    public let occurrenceStart: Date?

    public init(uid: String, start: Date, end: Date, isRecurring: Bool, occurrenceStart: Date?) {
        self.uid = uid
        self.start = start
        self.end = end
        self.isRecurring = isRecurring
        self.occurrenceStart = occurrenceStart
    }

    public var marker: String {
        Marker.encode(uid: uid, occurrenceStart: occurrenceStart, isRecurring: isRecurring)
    }
}

/// A "Busy" block we previously wrote into a destination calendar.
/// Identified by EventKit's stable `eventIdentifier` so the app can resolve it again.
public struct BusyCopy: Equatable, Sendable {
    public let eventID: String
    public let marker: String
    public let start: Date
    public let end: Date

    public init(eventID: String, marker: String, start: Date, end: Date) {
        self.eventID = eventID
        self.marker = marker
        self.start = start
        self.end = end
    }
}

public struct CreateItem: Equatable, Sendable {
    public let marker: String
    public let title: String
    public let start: Date
    public let end: Date
}

public struct UpdateItem: Equatable, Sendable {
    public let eventID: String
    public let marker: String
    public let title: String
    public let start: Date
    public let end: Date
}

public struct CancelItem: Equatable, Sendable {
    public let eventID: String
    public let marker: String
}

public struct PlanSummary: Equatable, Sendable {
    public let created: Int
    public let updated: Int
    public let cancelled: Int

    public var isEmpty: Bool { created == 0 && updated == 0 && cancelled == 0 }
}

public struct Plan: Equatable, Sendable {
    public let toCreate: [CreateItem]
    public let toUpdate: [UpdateItem]
    public let toCancel: [CancelItem]

    /// True when the mass-cancel guard suppressed this run's cancellations.
    public let guardTripped: Bool

    public var summary: PlanSummary {
        PlanSummary(created: toCreate.count, updated: toUpdate.count, cancelled: toCancel.count)
    }
}
