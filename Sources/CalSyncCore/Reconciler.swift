import Foundation

/// The heart of CalSync: given what's on the source calendar and what blocks already
/// exist on the destination, decide what to create, update, and cancel.
///
/// Pure — no EventKit, no I/O — which is why it can be exhaustively unit-tested.
public enum Reconciler {

    /// EventKit stores whole seconds; anything closer than this is the same instant,
    /// not a reschedule. Prevents sub-second drift from churning every block.
    static let timeTolerance: TimeInterval = 1.0

    static func timesDiffer(_ start: Date, _ end: Date, _ copy: BusyCopy) -> Bool {
        abs(start.timeIntervalSince(copy.start)) >= timeTolerance
            || abs(end.timeIntervalSince(copy.end)) >= timeTolerance
    }

    /// - Parameter cancelThreshold: if a single run would cancel more than this
    ///   fraction of existing blocks, all cancellations are suppressed. Guards against
    ///   a partial or offline calendar read wiping the mirror.
    /// - Parameter paddingMinutes: buffer added before and after each block. Applied
    ///   here rather than at write time so the padded window is what gets *compared*
    ///   too — otherwise every run would see a mismatch and rewrite every block.
    /// - Parameter now: the boundary between "expired" and "still ahead". Only events
    ///   that have not started are mirrored, so blocks fall behind this line simply by
    ///   the passage of time — see the cancel classification below.
    public static func reconcile(
        source: [SourceInstance],
        copies: [BusyCopy],
        busyTitle: String,
        cancelThreshold: Double,
        paddingMinutes: Int = 0,
        now: Date = Date()
    ) -> Plan {
        let padding = TimeInterval(max(0, paddingMinutes)) * 60
        let threshold = (cancelThreshold.isFinite && cancelThreshold >= 0 && cancelThreshold <= 1)
            ? cancelThreshold : 0.25

        var sourceByMarker: [String: SourceInstance] = [:]
        for instance in source {
            sourceByMarker[instance.marker] = instance
        }

        // First copy per marker wins. Any further copy sharing that marker is a
        // redundant duplicate: provably safe to remove, so it is EXEMPT from the
        // mass-cancel guard (the guard exists to catch a bad source read, and a
        // duplicate is not evidence of one). Without this, duplicates never converge.
        var copyByMarker: [String: BusyCopy] = [:]
        var duplicateCancels: [CancelItem] = []
        for copy in copies {
            if copyByMarker[copy.marker] != nil {
                duplicateCancels.append(CancelItem(eventID: copy.eventID, marker: copy.marker))
            } else {
                copyByMarker[copy.marker] = copy
            }
        }

        var toCreate: [CreateItem] = []
        var toUpdate: [UpdateItem] = []

        for (marker, instance) in sourceByMarker {
            let start = instance.start.addingTimeInterval(-padding)
            let end = instance.end.addingTimeInterval(padding)

            guard let existing = copyByMarker[marker] else {
                toCreate.append(CreateItem(
                    marker: marker, title: busyTitle, start: start, end: end))
                continue
            }
            // Title is deliberately not compared: every block is titled "Busy", so
            // renaming a source event must not churn its block. Only time matters.
            if timesDiffer(start, end, existing) {
                toUpdate.append(UpdateItem(
                    eventID: existing.eventID, marker: marker,
                    title: busyTitle, start: start, end: end))
            }
        }

        // Blocks with no matching source event fall into two very different groups.
        //
        //  - EXPIRED: the block's own start time has passed. Because only not-yet-started
        //    events are mirrored, every block becomes orphaned the moment its meeting
        //    begins. That is ordinary time passing, not evidence of a bad read, so these
        //    are exempt from the guard — otherwise each morning's starts would trip it and
        //    cleanup would jam permanently.
        //  - VANISHED: the block is still in the future but its source event is gone.
        //    That is the case the guard exists for (a partial or offline read).
        var guardedCancels: [CancelItem] = []
        var expiredCancels: [CancelItem] = []
        for (marker, copy) in copyByMarker where sourceByMarker[marker] == nil {
            let item = CancelItem(eventID: copy.eventID, marker: marker)
            if copy.start <= now {
                expiredCancels.append(item)
            } else {
                guardedCancels.append(item)
            }
        }

        var guardTripped = false
        var cancels = guardedCancels
        if !copies.isEmpty, Double(guardedCancels.count) / Double(copies.count) > threshold {
            guardTripped = true
            cancels = []
        }
        cancels += expiredCancels

        // Deterministic ordering so logs and tests are stable (dictionaries are not).
        toCreate.sort { $0.marker < $1.marker }
        toUpdate.sort { $0.marker < $1.marker }
        let toCancel = (cancels + duplicateCancels).sorted {
            $0.marker == $1.marker ? $0.eventID < $1.eventID : $0.marker < $1.marker
        }

        return Plan(toCreate: toCreate, toUpdate: toUpdate, toCancel: toCancel, guardTripped: guardTripped)
    }
}
