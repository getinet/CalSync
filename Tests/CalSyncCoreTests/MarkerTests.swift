import Foundation
import Testing
@testable import CalSyncCore

private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

@Suite("Marker encoding and parsing")
struct MarkerTests {

    @Test("single event marker omits the occurrence")
    func singleMarker() {
        #expect(Marker.encode(uid: "ABC", occurrenceStart: nil, isRecurring: false) == "x-calsync://ABC")
    }

    @Test("recurring marker appends the occurrence start")
    func recurringMarker() {
        let m = Marker.encode(uid: "ABC", occurrenceStart: t0, isRecurring: true)
        #expect(m.hasPrefix("x-calsync://ABC/"))
    }

    @Test("round-trips a plain uid")
    func roundTripSingle() {
        let m = Marker.encode(uid: "ABC", occurrenceStart: nil, isRecurring: false)
        #expect(Marker.parse(m) == Marker.Parsed(uid: "ABC", occurrenceStartISO: nil))
    }

    @Test("round-trips a uid containing slashes")
    func roundTripSlashedUID() {
        let m = Marker.encode(uid: "a/b/c", occurrenceStart: nil, isRecurring: false)
        #expect(Marker.parse(m)?.uid == "a/b/c")
    }

    // The bug this guards: if the uid were not percent-encoded, uid "a/b" and
    // uid "a" + occurrence "b" would produce the same string.
    @Test("a slashed uid never collides with a recurring marker")
    func markersAreInjective() {
        let single = Marker.encode(uid: "a/b", occurrenceStart: nil, isRecurring: false)
        let recurring = Marker.encode(uid: "a", occurrenceStart: t0, isRecurring: true)
        #expect(single != recurring)
        #expect(Marker.parse(single)?.uid == "a/b")
        #expect(Marker.parse(recurring)?.uid == "a")
    }

    @Test("uids needing percent-encoding survive a round trip",
          arguments: ["with space", "emoji-🚫-uid", "percent%sign", "plus+sign", "a/b?c#d"])
    func roundTripsAwkwardUIDs(uid: String) {
        let m = Marker.encode(uid: uid, occurrenceStart: nil, isRecurring: false)
        #expect(Marker.parse(m)?.uid == uid)
    }

    @Test("rejects anything that is not ours", arguments: [
        "https://example.com", "", "x-calsync-ish://ABC", "calsync://ABC",
    ])
    func rejectsForeignURLs(url: String) {
        #expect(Marker.parse(url) == nil)
    }

    @Test("nil url parses to nil rather than crashing")
    func rejectsNil() {
        #expect(Marker.parse(nil) == nil)
    }

    @Test("malformed percent-encoding returns nil instead of throwing",
          arguments: ["x-calsync://%ZZ", "x-calsync://%"])
    func malformedEncoding(url: String) {
        #expect(Marker.parse(url) == nil)
    }

    @Test("an empty uid is not a valid marker")
    func emptyUID() {
        #expect(Marker.parse("x-calsync://") == nil)
    }

    @Test("recognises our own blocks so they are never re-synced")
    func loopBackstop() {
        let ours = Marker.encode(uid: "X", occurrenceStart: nil, isRecurring: false)
        #expect(Marker.isCalSyncBlock(url: ours))
        #expect(!Marker.isCalSyncBlock(url: "https://zoom.us/j/123"))
        #expect(!Marker.isCalSyncBlock(url: nil))
    }

    // Second backstop, for when two calendars block each other directly: if a server
    // strips the URL, the marker is gone and only the title identifies our block.
    @Test("a block is recognised by title even without its marker")
    func titleBackstop() {
        #expect(Marker.looksLikeBlockTitle("Busy", busyTitle: "Busy"))
        #expect(Marker.looksLikeBlockTitle("  busy  ", busyTitle: "Busy"))
        #expect(Marker.looksLikeBlockTitle("BUSY", busyTitle: "Busy"))
        #expect(Marker.looksLikeBlockTitle("Unavailable", busyTitle: "Unavailable"))
    }

    @Test("real events are not mistaken for blocks")
    func titleBackstopIsNotOverEager() {
        #expect(!Marker.looksLikeBlockTitle("Busy with the Acme rollout", busyTitle: "Busy"))
        #expect(!Marker.looksLikeBlockTitle("Standup", busyTitle: "Busy"))
        #expect(!Marker.looksLikeBlockTitle(nil, busyTitle: "Busy"))
        #expect(!Marker.looksLikeBlockTitle("", busyTitle: "Busy"))
        #expect(!Marker.looksLikeBlockTitle("   ", busyTitle: "Busy"))
    }

    // An empty busy title must not turn every untitled event into a "block".
    @Test("an empty configured title matches nothing")
    func titleBackstopFailsClosed() {
        #expect(!Marker.looksLikeBlockTitle("", busyTitle: ""))
        #expect(!Marker.looksLikeBlockTitle("Standup", busyTitle: ""))
    }

    @Test("the exclusion marker opts an event out")
    func excludeMarker() {
        #expect(Marker.titleIsExcluded("Standup 🚫"))
        #expect(Marker.titleIsExcluded("🚫"))
        #expect(!Marker.titleIsExcluded("Standup"))
        #expect(!Marker.titleIsExcluded(""))
        #expect(!Marker.titleIsExcluded(nil))
    }
}
