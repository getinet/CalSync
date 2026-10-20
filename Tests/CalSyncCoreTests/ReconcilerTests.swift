import Foundation
import Testing
@testable import CalSyncCore

private let base = Date(timeIntervalSince1970: 1_780_000_000)
private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

private func instance(_ uid: String, start: Date = at(0), end: Date = at(1)) -> SourceInstance {
    SourceInstance(uid: uid, start: start, end: end, isRecurring: false, occurrenceStart: nil)
}

private func copy(of instance: SourceInstance, eventID: String) -> BusyCopy {
    BusyCopy(eventID: eventID, marker: instance.marker, start: instance.start, end: instance.end)
}

/// `now` is pinned just before the fixtures so every block in these tests counts as
/// still-ahead. Expiry has its own suite; these cases are about the guard and matching.
private func plan(source: [SourceInstance], copies: [BusyCopy], threshold: Double = 0.25) -> Plan {
    Reconciler.reconcile(source: source, copies: copies, busyTitle: "Busy",
                         cancelThreshold: threshold, paddingMinutes: 0,
                         now: base.addingTimeInterval(-3600))
}

@Suite("Reconciler")
struct ReconcilerTests {

    @Test("a source event with no block is created, titled Busy")
    func createsMissingBlock() {
        let result = plan(source: [instance("A")], copies: [])
        #expect(result.summary == PlanSummary(created: 1, updated: 0, cancelled: 0))
        #expect(result.toCreate.first?.title == "Busy")
        #expect(result.toCreate.first?.start == at(0))
    }

    @Test("an unchanged event produces no work")
    func noopWhenUnchanged() {
        let a = instance("A")
        let result = plan(source: [a], copies: [copy(of: a, eventID: "e1")])
        #expect(result.summary.isEmpty)
    }

    @Test("a rescheduled event updates its block in place")
    func updatesOnReschedule() {
        let a = instance("A")
        let moved = instance("A", start: at(5), end: at(6))
        let result = plan(source: [moved], copies: [copy(of: a, eventID: "e1")])
        #expect(result.summary == PlanSummary(created: 0, updated: 1, cancelled: 0))
        #expect(result.toUpdate.first?.eventID == "e1")
        #expect(result.toUpdate.first?.start == at(5))
    }

    // Every block is titled "Busy", so a source rename must not cause churn — there is
    // nothing on the block that could reflect the change.
    @Test("renaming the source event does not touch the block")
    func renameCausesNoUpdate() {
        let a = instance("A")
        let result = plan(source: [a], copies: [copy(of: a, eventID: "e1")])
        #expect(result.summary.isEmpty)
    }

    @Test("sub-second drift is not treated as a reschedule")
    func toleratesSubSecondDrift() {
        let a = instance("A")
        let drifted = BusyCopy(eventID: "e1", marker: a.marker,
                               start: a.start.addingTimeInterval(0.4),
                               end: a.end.addingTimeInterval(-0.4))
        #expect(plan(source: [a], copies: [drifted]).summary.isEmpty)
    }

    @Test("a block whose source event vanished is cancelled")
    func cancelsOrphanedBlock() {
        let a = instance("A"), b = instance("B"), c = instance("C"), d = instance("D")
        let copies = [copy(of: a, eventID: "e1"), copy(of: b, eventID: "e2"),
                      copy(of: c, eventID: "e3"), copy(of: d, eventID: "e4")]
        let result = plan(source: [a, b, c], copies: copies)   // D disappeared: 1 of 4 = 25%
        #expect(result.guardTripped == false)
        #expect(result.toCancel.map(\.eventID) == ["e4"])
    }

    @Test("the mass-cancel guard suppresses an implausible wipe")
    func guardTripsAboveThreshold() {
        let all = (1...4).map { instance("E\($0)") }
        let copies = all.enumerated().map { copy(of: $1, eventID: "e\($0)") }
        let result = plan(source: [], copies: copies)          // everything gone: 100%
        #expect(result.guardTripped)
        #expect(result.toCancel.isEmpty)
    }

    @Test("the guard sits at 'more than', so exactly-at-threshold still cancels")
    func guardIsExclusive() {
        let all = (1...4).map { instance("E\($0)") }
        let copies = all.enumerated().map { copy(of: $1, eventID: "e\($0)") }
        let result = plan(source: Array(all.dropLast()), copies: copies)  // 25% exactly
        #expect(result.guardTripped == false)
        #expect(result.toCancel.count == 1)
    }

    @Test("an empty destination calendar never trips the guard")
    func guardIgnoresEmptyMirror() {
        let result = plan(source: [instance("A")], copies: [])
        #expect(result.guardTripped == false)
    }

    // Duplicates are provably safe to remove, so they must be cancelled even while the
    // guard is suppressing everything else — otherwise duplicates never converge.
    @Test("duplicate blocks are removed even when the guard trips")
    func duplicatesAreGuardExempt() {
        let a = instance("A")
        let copies = [copy(of: a, eventID: "keep"), copy(of: a, eventID: "dupe"),
                      copy(of: instance("B"), eventID: "orphan1"),
                      copy(of: instance("C"), eventID: "orphan2")]
        let result = plan(source: [a], copies: copies)
        #expect(result.guardTripped)
        #expect(result.toCancel.map(\.eventID) == ["dupe"])   // orphans spared, dupe removed
    }

    @Test("the surviving duplicate is not also updated or recreated")
    func duplicateCollapseKeepsOne() {
        let a = instance("A")
        let result = plan(source: [a], copies: [copy(of: a, eventID: "keep"), copy(of: a, eventID: "dupe")])
        #expect(result.toCreate.isEmpty)
        #expect(result.toUpdate.isEmpty)
        #expect(result.toCancel.count == 1)
    }

    // A moved occurrence changes its marker, so it cannot be updated in place.
    @Test("a moved recurring occurrence becomes cancel-old plus create-new")
    func movedOccurrenceIsCancelAndCreate() {
        let original = SourceInstance(uid: "R", start: at(0), end: at(1),
                                      isRecurring: true, occurrenceStart: at(0))
        let moved = SourceInstance(uid: "R", start: at(3), end: at(4),
                                   isRecurring: true, occurrenceStart: at(3))
        let result = plan(source: [moved], copies: [copy(of: original, eventID: "old")], threshold: 1.0)
        #expect(result.toCreate.count == 1)
        #expect(result.toCancel.map(\.eventID) == ["old"])
        #expect(result.toUpdate.isEmpty)
    }

    @Test("occurrences of one series are tracked independently")
    func recurringOccurrencesAreDistinct() {
        let first = SourceInstance(uid: "R", start: at(0), end: at(1), isRecurring: true, occurrenceStart: at(0))
        let second = SourceInstance(uid: "R", start: at(24), end: at(25), isRecurring: true, occurrenceStart: at(24))
        #expect(first.marker != second.marker)
        let result = plan(source: [first, second], copies: [copy(of: first, eventID: "e1")])
        #expect(result.summary == PlanSummary(created: 1, updated: 0, cancelled: 0))
    }

    @Test("an out-of-range threshold falls back to the 25% default")
    func invalidThresholdFallsBack() {
        let all = (1...4).map { instance("E\($0)") }
        let copies = all.enumerated().map { copy(of: $1, eventID: "e\($0)") }
        #expect(plan(source: [], copies: copies, threshold: .nan).guardTripped)
        #expect(plan(source: [], copies: copies, threshold: -3).guardTripped)
    }

    @Test("a custom busy title is applied to created blocks")
    func honoursCustomTitle() {
        let result = Reconciler.reconcile(source: [instance("A")], copies: [],
                                          busyTitle: "Unavailable", cancelThreshold: 0.25)
        #expect(result.toCreate.first?.title == "Unavailable")
    }
}
