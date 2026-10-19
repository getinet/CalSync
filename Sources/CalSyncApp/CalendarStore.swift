import EventKit
import Foundation
import CalSyncCore

struct CalendarInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let accountName: String
    let isWritable: Bool

    var displayLabel: String { accountName.isEmpty ? name : "\(name) (\(accountName))" }

    var ref: CalendarRef { CalendarRef(id: id, name: name, accountName: accountName) }
}

enum CalendarError: LocalizedError {
    case accessDenied
    case calendarNotFound(String)
    case calendarNotWritable(String)
    case cannotCreateCalendar(account: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "CalSync does not have full access to your calendars. "
                 + "Grant it in System Settings → Privacy & Security → Calendars."
        case .calendarNotFound(let name):
            return "Calendar “\(name)” no longer exists. Re-pick it in Settings."
        case .calendarNotWritable(let name):
            return "Calendar “\(name)” is read-only, so Busy blocks cannot be written to it."
        case .cannotCreateCalendar(let account, let underlying):
            return "Could not create a calendar in “\(account)”: \(underlying) "
                 + "Some account types disallow this. Create the calendar in Calendar.app, "
                 + "then pick it here."
        }
    }
}

/// Everything that touches EventKit. Confined to the main actor: `EKEventStore` is not
/// Sendable, and the event volumes here (a few hundred, at most) never justify the
/// complexity of moving it off.
@MainActor
final class CalendarStore {
    private let store = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var hasFullAccess: Bool { authorizationStatus == .fullAccess }

    /// Full access is required: write-only access (status `.writeOnly`) cannot read the
    /// source calendar, which is half of what this app does.
    func requestAccess() async -> Bool {
        if hasFullAccess { return true }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            Log.write("ERROR calendar access request failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Discovery (drives the Settings pickers)

    func allCalendars() -> [CalendarInfo] {
        store.calendars(for: .event)
            .map {
                CalendarInfo(id: $0.calendarIdentifier,
                             name: $0.title,
                             accountName: $0.source?.title ?? "",
                             isWritable: $0.allowsContentModifications)
            }
            .sorted {
                $0.accountName == $1.accountName
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending
            }
    }

    func accounts() -> [(id: String, title: String)] {
        // Only sources that can actually hold new calendars are worth offering.
        store.sources
            .filter { !$0.calendars(for: .event).isEmpty }
            .map { (id: $0.sourceIdentifier, title: $0.title) }
    }

    func createCalendar(named name: String, inAccountWithID sourceID: String) throws -> CalendarInfo {
        guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceID }) else {
            throw CalendarError.cannotCreateCalendar(account: sourceID, underlying: "account not found.")
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = name
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw CalendarError.cannotCreateCalendar(
                account: source.title, underlying: error.localizedDescription)
        }
        Log.write("INFO created calendar “\(name)” in \(source.title)")
        return CalendarInfo(id: calendar.calendarIdentifier, name: calendar.title,
                            accountName: source.title, isWritable: true)
    }

    private func calendar(withID id: String, label: String) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: id) else {
            throw CalendarError.calendarNotFound(label)
        }
        return calendar
    }

    // MARK: - Reading

    /// Concrete, timed events in the window. EventKit expands recurring series into
    /// occurrences and applies exceptions — the reason reads go through EventKit rather
    /// than Calendar.app scripting, which only ever returned the unexpanded master.
    func sourceInstances(calendarID: String, label: String, busyTitle: String,
                         from: Date, to: Date) throws -> [SourceInstance] {
        let calendar = try calendar(withID: calendarID, label: label)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])

        var instances: [SourceInstance] = []
        var skippedAllDay = 0, skippedExcluded = 0, skippedOurs = 0, skippedNoUID = 0, skippedStarted = 0

        for event in store.events(matching: predicate) {
            if event.isAllDay { skippedAllDay += 1; continue }

            // Future events only. EventKit's predicate matches anything *overlapping*
            // the window, which includes meetings already underway — those are excluded
            // here, so a block disappears once its meeting begins.
            if event.startDate <= from { skippedStarted += 1; continue }

            // Loop backstops: never treat one of our own blocks as a source event. The
            // marker is the primary check; the title catches a block whose URL was
            // stripped by a calendar server. Both matter when two calendars block each
            // other directly.
            if Marker.isCalSyncBlock(url: event.url?.absoluteString)
                || Marker.looksLikeBlockTitle(event.title, busyTitle: busyTitle) {
                skippedOurs += 1
                continue
            }

            if Marker.titleIsExcluded(event.title) { skippedExcluded += 1; continue }

            guard let uid = event.calendarItemExternalIdentifier, !uid.isEmpty else {
                skippedNoUID += 1
                continue
            }

            var occurrence: Date?
            if event.hasRecurrenceRules {
                occurrence = event.occurrenceDate
                if occurrence == nil { occurrence = event.startDate }
            }

            instances.append(SourceInstance(
                uid: uid,
                start: event.startDate,
                end: event.endDate,
                isRecurring: event.hasRecurrenceRules,
                occurrenceStart: occurrence))
        }

        if skippedAllDay + skippedExcluded + skippedOurs + skippedNoUID + skippedStarted > 0 {
            Log.write("INFO \(label): skipped allDay=\(skippedAllDay) excluded=\(skippedExcluded) "
                    + "ourBlocks=\(skippedOurs) noUID=\(skippedNoUID) alreadyStarted=\(skippedStarted)")
        }
        return instances
    }

    /// Blocks we previously wrote. Anything in the destination calendar without one of
    /// our markers is somebody else's event and is left strictly alone.
    func existingBlocks(calendarID: String, label: String, from: Date, to: Date) throws -> [BusyCopy] {
        let calendar = try calendar(withID: calendarID, label: label)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])

        return store.events(matching: predicate).compactMap { event in
            guard Marker.isCalSyncBlock(url: event.url?.absoluteString),
                  let marker = event.url?.absoluteString,
                  let id = event.eventIdentifier
            else { return nil }
            return BusyCopy(eventID: id, marker: marker, start: event.startDate, end: event.endDate)
        }
    }

    // MARK: - Writing

    struct ApplyResult { var created = 0, updated = 0, cancelled = 0, failed = 0 }

    func apply(_ plan: Plan, toCalendarID calendarID: String, label: String) throws -> ApplyResult {
        let calendar = try calendar(withID: calendarID, label: label)
        guard calendar.allowsContentModifications else {
            throw CalendarError.calendarNotWritable(label)
        }

        var result = ApplyResult()

        // A single event failing must never abort the rest of the run.
        for item in plan.toCreate {
            do {
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                event.title = item.title
                event.startDate = item.start
                event.endDate = item.end
                event.url = URL(string: item.marker)
                try store.save(event, span: .thisEvent, commit: false)
                result.created += 1
            } catch {
                result.failed += 1
                Log.write("ERROR create \(item.marker): \(error.localizedDescription)")
            }
        }

        for item in plan.toUpdate {
            do {
                guard let event = store.event(withIdentifier: item.eventID) else {
                    result.failed += 1
                    Log.write("WARN update skipped, block vanished: \(item.marker)")
                    continue
                }
                event.startDate = item.start
                event.endDate = item.end
                event.title = item.title
                try store.save(event, span: .thisEvent, commit: false)
                result.updated += 1
            } catch {
                result.failed += 1
                Log.write("ERROR update \(item.marker): \(error.localizedDescription)")
            }
        }

        for item in plan.toCancel {
            do {
                guard let event = store.event(withIdentifier: item.eventID) else {
                    continue  // already gone; nothing to do
                }
                try store.remove(event, span: .thisEvent, commit: false)
                result.cancelled += 1
            } catch {
                result.failed += 1
                Log.write("ERROR cancel \(item.marker): \(error.localizedDescription)")
            }
        }

        try store.commit()
        return result
    }
}
