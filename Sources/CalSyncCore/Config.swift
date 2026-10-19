import Foundation

/// Reference to a calendar. Identity is EventKit's `calendarIdentifier` — stable across
/// renames and unambiguous when two accounts hold same-named calendars. `name` and
/// `accountName` are cached for display only and are refreshed on each settings load.
public struct CalendarRef: Codable, Equatable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var accountName: String

    public init(id: String, name: String, accountName: String) {
        self.id = id
        self.name = name
        self.accountName = accountName
    }

    public var displayLabel: String {
        accountName.isEmpty ? name : "\(name) (\(accountName))"
    }
}

/// One direction of sync: events on `source` produce "Busy" blocks on `mirrorTo`.
/// `mirrorTo` lives in the *other* account — that is the whole point.
public struct SyncSide: Codable, Equatable, Sendable {
    public var id: String
    public var source: CalendarRef
    public var mirrorTo: CalendarRef

    public init(id: String, source: CalendarRef, mirrorTo: CalendarRef) {
        self.id = id
        self.source = source
        self.mirrorTo = mirrorTo
    }
}

public enum NotificationPolicy: String, Codable, Sendable, CaseIterable {
    /// Notify on errors, and whenever a sync actually changed something.
    case changes
    /// Notify only when a sync fails.
    case errors
    case off

    public var label: String {
        switch self {
        case .changes: return "Errors and changes"
        case .errors: return "Errors only"
        case .off: return "Never"
        }
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var sides: [SyncSide]
    public var busyTitle: String
    public var windowDays: Int
    public var cancelThreshold: Double
    public var syncIntervalMinutes: Int
    public var notifications: NotificationPolicy

    /// Buffer added on each side of a mirrored block, so back-to-back bookings across
    /// the two accounts leave travel/reset time. 5 minutes each way by default.
    public var paddingMinutes: Int

    public init(
        sides: [SyncSide] = [],
        busyTitle: String = "Busy",
        windowDays: Int = 30,
        cancelThreshold: Double = 0.25,
        syncIntervalMinutes: Int = 60,
        notifications: NotificationPolicy = .changes,
        paddingMinutes: Int = 5
    ) {
        self.sides = sides
        self.busyTitle = busyTitle
        self.windowDays = windowDays
        self.cancelThreshold = cancelThreshold
        self.syncIntervalMinutes = syncIntervalMinutes
        self.notifications = notifications
        self.paddingMinutes = paddingMinutes
    }

    // Older stored settings predate padding; default it rather than failing to decode.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sides = try c.decodeIfPresent([SyncSide].self, forKey: .sides) ?? []
        busyTitle = try c.decodeIfPresent(String.self, forKey: .busyTitle) ?? "Busy"
        windowDays = try c.decodeIfPresent(Int.self, forKey: .windowDays) ?? 30
        cancelThreshold = try c.decodeIfPresent(Double.self, forKey: .cancelThreshold) ?? 0.25
        syncIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes) ?? 60
        notifications = try c.decodeIfPresent(NotificationPolicy.self, forKey: .notifications) ?? .changes
        paddingMinutes = try c.decodeIfPresent(Int.self, forKey: .paddingMinutes) ?? 5
    }

    /// True once both directions are configured. Until then the app syncs nothing.
    public var isConfigured: Bool { ConfigValidator.validate(self) == nil }
}

public enum ConfigValidator {

    /// Returns a human-readable problem, or nil when the config is safe to run.
    ///
    /// Deliberately permissive about one arrangement that looks alarming but is fine:
    /// **one side's destination may be the other side's source.** That is the natural
    /// "two calendars block each other directly" setup, and it does not loop, because
    /// the reader skips events carrying our marker or our block title.
    ///
    /// What genuinely breaks is rejected below.
    public static func validate(_ config: AppConfig) -> String? {
        guard config.sides.count == 2 else {
            return "Pick a calendar for both sides before syncing."
        }

        for side in config.sides {
            for (role, ref) in [("source", side.source), ("destination", side.mirrorTo)] {
                if ref.id.trimmingCharacters(in: .whitespaces).isEmpty {
                    return "The \(side.id) \(role) calendar is not set."
                }
            }
        }

        // Both sides writing into one calendar is the real conflict: each side sees the
        // other's blocks as orphans and deletes them, every single run, forever.
        if config.sides[0].mirrorTo.id == config.sides[1].mirrorTo.id {
            return "Both sides would write Busy blocks into the same calendar "
                 + "(\(config.sides[0].mirrorTo.displayLabel)). Each side would delete the "
                 + "other's blocks. Give them separate destinations."
        }

        // Mirroring a calendar onto itself just litters it with Busy copies of its own events.
        for side in config.sides where side.source.id == side.mirrorTo.id {
            return "The \(side.id) side reads and writes the same calendar "
                 + "(\(side.source.displayLabel)), which would fill it with Busy copies of "
                 + "its own events."
        }

        // Two sides reading one calendar is always a mis-pick in a two-calendar app.
        if config.sides[0].source.id == config.sides[1].source.id {
            return "Both sides are reading the same calendar "
                 + "(\(config.sides[0].source.displayLabel)). Pick your two different calendars."
        }

        if config.busyTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            return "The busy title cannot be empty."
        }
        guard config.windowDays > 0, config.windowDays <= 365 else {
            return "Sync window must be between 1 and 365 days."
        }
        guard config.cancelThreshold >= 0, config.cancelThreshold <= 1 else {
            return "Cancel threshold must be between 0 and 1."
        }
        guard config.syncIntervalMinutes >= 1 else {
            return "Sync interval must be at least 1 minute."
        }
        guard config.paddingMinutes >= 0, config.paddingMinutes <= 120 else {
            return "Buffer must be between 0 and 120 minutes."
        }
        return nil
    }
}
