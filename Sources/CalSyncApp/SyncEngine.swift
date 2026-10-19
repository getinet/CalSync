import Foundation
import CalSyncCore

struct SyncOutcome: Sendable {
    var finishedAt = Date()
    var created = 0
    var updated = 0
    var cancelled = 0
    var failed = 0
    var guardTripped = false
    var errors: [String] = []

    var changed: Bool { created + updated + cancelled > 0 }
    var hasProblem: Bool { !errors.isEmpty || failed > 0 || guardTripped }

    var shortSummary: String {
        if !errors.isEmpty { return "Sync failed" }
        if !changed { return "Up to date" }
        var parts: [String] = []
        if created > 0 { parts.append("\(created) added") }
        if updated > 0 { parts.append("\(updated) moved") }
        if cancelled > 0 { parts.append("\(cancelled) removed") }
        return parts.joined(separator: ", ")
    }
}

/// Runs both directions. Each side is independent: a broken company calendar must not
/// stop the client side from syncing.
@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastOutcome: SyncOutcome?

    private let calendars: CalendarStore
    private let settings: SettingsStore

    init(calendars: CalendarStore, settings: SettingsStore) {
        self.calendars = calendars
        self.settings = settings
    }

    @discardableResult
    func syncNow(trigger: String) async -> SyncOutcome? {
        guard !isSyncing else { return nil }

        let config = settings.config
        if let problem = ConfigValidator.validate(config) {
            Log.write("SKIP (\(trigger)) not configured: \(problem)")
            return nil
        }
        guard calendars.hasFullAccess else {
            let outcome = SyncOutcome(errors: [CalendarError.accessDenied.localizedDescription])
            Log.write("ABORT (\(trigger)) no calendar access")
            lastOutcome = outcome
            notify(outcome, policy: config.notifications)
            return outcome
        }

        isSyncing = true
        defer { isSyncing = false }

        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(config.windowDays) * 86_400)

        // Blocks are read from slightly further back than events are. A block is removed
        // once its meeting starts, so it is normally still inside the window when that
        // happens — but if the Mac was asleep overnight, the meeting may have finished
        // entirely. The lookback lets those stragglers be cleaned up rather than stranded.
        let blockWindowStart = now.addingTimeInterval(-86_400)
        var outcome = SyncOutcome()

        for side in config.sides {
            do {
                let instances = try calendars.sourceInstances(
                    calendarID: side.source.id, label: side.source.displayLabel,
                    busyTitle: config.busyTitle, from: now, to: end)
                let blocks = try calendars.existingBlocks(
                    calendarID: side.mirrorTo.id, label: side.mirrorTo.displayLabel,
                    from: blockWindowStart, to: end)

                let plan = Reconciler.reconcile(
                    source: instances, copies: blocks,
                    busyTitle: config.busyTitle, cancelThreshold: config.cancelThreshold,
                    paddingMinutes: config.paddingMinutes, now: now)

                if plan.guardTripped {
                    outcome.guardTripped = true
                    Log.write("GUARD \(side.id): would cancel more than "
                            + "\(Int(config.cancelThreshold * 100))% of \(blocks.count) blocks, "
                            + "so cancellations were suppressed this run")
                }

                let applied = try calendars.apply(
                    plan, toCalendarID: side.mirrorTo.id, label: side.mirrorTo.displayLabel)

                outcome.created += applied.created
                outcome.updated += applied.updated
                outcome.cancelled += applied.cancelled
                outcome.failed += applied.failed

                Log.write("RUN \(side.id) (\(trigger)) source=\(instances.count) blocks=\(blocks.count) "
                        + "created=\(applied.created) updated=\(applied.updated) "
                        + "cancelled=\(applied.cancelled) failed=\(applied.failed)")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                outcome.errors.append("\(side.id): \(message)")
                Log.write("ERROR \(side.id) (\(trigger)): \(message)")
            }
        }

        lastOutcome = outcome
        notify(outcome, policy: config.notifications)
        return outcome
    }

    private func notify(_ outcome: SyncOutcome, policy: NotificationPolicy) {
        if !outcome.errors.isEmpty {
            Notifier.post(title: "CalSync couldn’t sync",
                          body: outcome.errors.joined(separator: "\n"),
                          policy: policy, isError: true)
        } else if outcome.guardTripped {
            Notifier.post(title: "CalSync paused removals",
                          body: "An unusual number of Busy blocks would have been deleted, so "
                              + "they were kept. They will be re-checked on the next sync.",
                          policy: policy, isError: true)
        } else if outcome.changed {
            Notifier.post(title: "Calendars synced",
                          body: outcome.shortSummary, policy: policy, isError: false)
        }
    }
}
