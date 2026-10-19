import Foundation
import Testing
@testable import CalSyncCore

private let now = Date(timeIntervalSince1970: 1_780_000_000)
private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }
private func mins(_ m: Double) -> TimeInterval { m * 60 }

private func instance(_ uid: String, start: Date, end: Date) -> SourceInstance {
    SourceInstance(uid: uid, start: start, end: end, isRecurring: false, occurrenceStart: nil)
}

private func plan(source: [SourceInstance], copies: [BusyCopy],
                  padding: Int = 5, threshold: Double = 0.25) -> Plan {
    Reconciler.reconcile(source: source, copies: copies, busyTitle: "Busy",
                         cancelThreshold: threshold, paddingMinutes: padding, now: now)
}

@Suite("Buffer padding")
struct PaddingTests {

    @Test("a created block starts early and ends late by the buffer")
    func paddingWidensTheBlock() {
        let event = instance("A", start: at(2), end: at(3))
        let created = plan(source: [event], copies: []).toCreate
        #expect(created.first?.start == at(2).addingTimeInterval(-mins(5)))
        #expect(created.first?.end == at(3).addingTimeInterval(mins(5)))
    }

    @Test("zero buffer mirrors the exact event times")
    func noPadding() {
        let event = instance("A", start: at(2), end: at(3))
        let created = plan(source: [event], copies: [], padding: 0).toCreate
        #expect(created.first?.start == at(2))
        #expect(created.first?.end == at(3))
    }

    // The trap: if padding were applied at write time but not when comparing, every run
    // would see a mismatch and rewrite every block forever.
    @Test("an already-padded block is not rewritten on the next run")
    func paddedBlockIsStable() {
        let event = instance("A", start: at(2), end: at(3))
        let existing = BusyCopy(eventID: "e1", marker: event.marker,
                                start: at(2).addingTimeInterval(-mins(5)),
                                end: at(3).addingTimeInterval(mins(5)))
        #expect(plan(source: [event], copies: [existing]).summary.isEmpty)
    }

    @Test("changing the buffer restyles existing blocks exactly once")
    func changingPaddingUpdatesBlocks() {
        let event = instance("A", start: at(2), end: at(3))
        let fivePadded = BusyCopy(eventID: "e1", marker: event.marker,
                                  start: at(2).addingTimeInterval(-mins(5)),
                                  end: at(3).addingTimeInterval(mins(5)))
        let updated = plan(source: [event], copies: [fivePadded], padding: 15).toUpdate
        #expect(updated.first?.start == at(2).addingTimeInterval(-mins(15)))

        let fifteenPadded = BusyCopy(eventID: "e1", marker: event.marker,
                                     start: at(2).addingTimeInterval(-mins(15)),
                                     end: at(3).addingTimeInterval(mins(15)))
        #expect(plan(source: [event], copies: [fifteenPadded], padding: 15).summary.isEmpty)
    }

    @Test("a negative buffer is clamped rather than inverting the block")
    func negativePaddingClamped() {
        let event = instance("A", start: at(2), end: at(3))
        let created = plan(source: [event], copies: [], padding: -30).toCreate
        #expect(created.first?.start == at(2))
    }
}

@Suite("Expired blocks")
struct ExpiryTests {

    // Only not-yet-started events are mirrored, so a block whose start has passed is
    // orphaned by ordinary time passing — not by a suspicious read.
    @Test("a block whose start has passed is cancelled")
    func expiredBlockIsCancelled() {
        let stale = BusyCopy(eventID: "old", marker: "x-calsync://GONE", start: at(-2), end: at(-1))
        let result = plan(source: [], copies: [stale])
        #expect(result.toCancel.map(\.eventID) == ["old"])
    }

    // The regression this prevents: every morning's meeting starts would look like a
    // mass deletion, trip the guard, and jam cleanup permanently.
    @Test("expired blocks are exempt from the mass-cancel guard")
    func expiryDoesNotTripTheGuard() {
        let expired = (1...4).map {
            BusyCopy(eventID: "e\($0)", marker: "x-calsync://E\($0)", start: at(-3), end: at(-2))
        }
        let result = plan(source: [], copies: expired)
        #expect(result.guardTripped == false)
        #expect(result.toCancel.count == 4)
    }

    @Test("a future block whose event vanished is still guarded")
    func futureOrphansStayGuarded() {
        let future = (1...4).map {
            BusyCopy(eventID: "f\($0)", marker: "x-calsync://F\($0)", start: at(5), end: at(6))
        }
        let result = plan(source: [], copies: future)
        #expect(result.guardTripped)
        #expect(result.toCancel.isEmpty)
    }

    // Mixed is the realistic case: some blocks aged out while a read genuinely failed.
    @Test("expired blocks are cleaned even while the guard protects future ones")
    func expiredAndGuardedTogether() {
        let expired = BusyCopy(eventID: "past", marker: "x-calsync://P", start: at(-1), end: at(-0.5))
        let future = (1...4).map {
            BusyCopy(eventID: "f\($0)", marker: "x-calsync://F\($0)", start: at(5), end: at(6))
        }
        let result = plan(source: [], copies: [expired] + future)
        #expect(result.guardTripped)
        #expect(result.toCancel.map(\.eventID) == ["past"])
    }

    @Test("a block exactly at the boundary counts as expired")
    func boundaryIsExpired() {
        let boundary = BusyCopy(eventID: "b", marker: "x-calsync://B", start: now, end: at(1))
        #expect(plan(source: [], copies: [boundary]).toCancel.count == 1)
    }
}
