# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Writing rules for this project.** In human readable text (docs, UI strings, commit
> messages, replies) use no dashes of any kind, never the word "just", and no contrast
> framing such as "not X, but Y". Personality and light humor are welcome. Code and code
> comments are exempt.

## What this is

CalSync is a macOS **menu bar app** that stops a company calendar and a client calendar
from being double booked. An event on either calendar produces a block titled "Busy" on
the other. Only times cross over. Titles, notes, locations, and guests never do.

Swift 6 with SwiftPM, macOS 14 and later. There is no `.xcodeproj`. The `.app` bundle is
assembled by `build.sh`, because SwiftPM emits a bare executable and macOS grants
calendar access to a bundle with a stable identity.

> **History.** This repo previously held a one way JXA (`osascript`) script that mirrored
> a work calendar to a personal one through emailed invitations. All of it is gone. The
> documents under `docs/superpowers/` describe that superseded v1 and survive only as a
> record. Treat them as history.

## Commands

```bash
swift test
```

```bash
swift test --filter ExpiryTests
```

Filters by suite or test name. The 55 tests cover `CalSyncCore`. The EventKit and AppKit
layers have none, for reasons under Testing reality.

```bash
./build.sh
```

Release build, assembles and ad hoc signs `dist/CalSync.app`.

```bash
./build.sh --install
```

Also copies into `/Applications` and launches it.

## Architecture

Two targets, and the split is the important part:

* **`Sources/CalSyncCore`** holds pure logic: markers, reconciliation, config validation.
  No EventKit, no AppKit, no I/O, no clock, since `now` is always injected. Nearly all
  the risk lives here, which is why it carries all the tests.
* **`Sources/CalSyncApp`** holds everything impure. `CalendarStore` is the single
  EventKit boundary. `SyncEngine` wires core to store. `AppDelegate` owns the status item
  and scheduling. `SettingsView` is the calendar picker.

Reads and writes both go through EventKit. Reads have to, because Calendar.app scripting
returns only the unexpanded master of a recurring series. Writes go through EventKit
because nothing requires Calendar.app any more, now that v1's invitation emails are gone.

### Two independent directions

`AppConfig.sides` holds exactly two `SyncSide` values, `"company"` and `"client"`. Each
is one run of read, reconcile, apply. Each is independently error contained, so a broken
company calendar leaves the client side working.

### Identity: self describing blocks, no state file

A block stores its own identity in the event `url` field. `x-calsync://<uid>` for a
single event, `x-calsync://<uid>/<occurrenceISO>` for a recurring occurrence. Every run
rederives all state by reading both calendars. Nothing persists between runs except
settings.

The consequence: a moved single event keeps its marker and gets updated in place. A moved
recurring occurrence earns a new marker, so it becomes cancel old plus create new. That
is deliberate.

The uid is percent encoded before going into the marker. Skip that and uid `a/b` collides
with uid `a` plus occurrence `b`.

## Invariants, and please leave them alone

* **Loop prevention lives in the reader, not in the config rules.** Two independent
  backstops sit in `sourceInstances`: `Marker.isCalSyncBlock` on the event url, and
  `Marker.looksLikeBlockTitle` on the event title. The title check earns its keep because
  the url is not guaranteed to survive a round trip through every CalDAV server. Strip a
  marker and the block reads as a real event, gets mirrored back, loses its own marker,
  and multiplies without limit. Keep both. One is not enough when two calendars block
  each other directly.
* **A destination may be the other side's source.** That is the ordinary two calendar
  setup, A and B blocking each other with no dedicated calendars, and it has to stay
  legal. `ConfigValidator` rejects only what genuinely breaks: two equal destinations
  (each side deletes the other's blocks every run), a side whose source is its own
  destination, and two equal sources.
* **Padding is applied in the reconciler, never at write time.** It has to shape the
  times used for comparison as well as the ones written. Miss that and every run sees a
  mismatch and rewrites every block forever.
* **Cancellations are classified, never lumped together.** Three kinds, and the
  distinction carries weight:
  * *duplicates*, two blocks with one marker. Always cancelled, exempt from the guard,
    provably safe.
  * *expired*, the block start has passed. Always cancelled, exempt from the guard. Only
    events that have yet to start get mirrored, so blocks orphan themselves as time
    passes. Count these toward the guard and every morning's meeting starts trip it,
    jamming cleanup permanently.
  * *vanished*, still in the future with the source gone. **Guarded.** This is the single
    case the mass cancel guard exists for, a partial or offline calendar read.
* **Only events that have yet to start are mirrored.** `event.startDate <= from` gets
  skipped. The user picked this knowing the cost: a block disappears when its meeting
  begins, so the other calendar reads as free mid meeting. Leave it be unless asked.
* **Blocks are read from a wider window than events**, 24 hours further back. A block
  normally goes away at its meeting start while still inside the window. The lookback
  catches stragglers left behind by a sleeping Mac. Narrow it and blocks strand in the
  past.
* **Only marked events are ever touched.** Anything in a destination calendar without an
  `x-calsync://` url belongs to somebody else.

## Gotchas this codebase already walked into

* **Swift 6 strict concurrency.** `ISO8601DateFormatter` is not `Sendable` and cannot be
  a shared `static let`. Use `Date.ISO8601FormatStyle`, a value type. The same trap waits
  behind any other Foundation formatter.
* **`EKEventStoreChanged` fires for our own writes.** `AppDelegate` guards with
  `ignoreStoreChangesUntil`, 15 seconds after each sync, plus a 10 second debounce. Drop
  either and a sync retriggers itself in a loop.
* **An `LSUIElement` app ignores `osascript -e 'quit app "CalSync"'`, and `open` on a
  running app only activates it.** `build.sh --install` therefore force quits, waits for
  the process to exit, and fails loudly. Without that you silently keep running the old
  binary over a freshly copied bundle, which cost real debugging time once already.
* **The filesystem here is case insensitive**, so `tests/` and `Tests/` are one
  directory. SwiftPM wants `Tests/`. Confirm the directory case in git rather than on
  disk, since a case sensitive checkout would fail to find the test target.
* **`NSCalendarsFullAccessUsageDescription` is mandatory** in `Info.plist`. Leave it out
  and macOS silently denies calendar access. No prompt, no error, no access.
* **Editing `Info.plist` invalidates the signature** and TCC insists on a valid one, so
  `build.sh` re-signs afterwards. Re-signing changes the app identity, so the calendar
  grant may want re-approving after a rebuild.
* **`EKEventStore` is not Sendable.** `CalendarStore` is `@MainActor` throughout. Event
  volumes stay small enough that moving it off the main actor would buy nothing.
* **A status item with no image and no title collapses to zero width** and looks exactly
  like the app failing to launch. `applyStatusImage` falls back through the drawn mark, a
  system symbol, then plain text.

## Icon

`AppIcon.swift` draws the mark with Core Graphics, and one routine feeds the app icon,
the menu bar template, and the 56pt image in Settings. `build.sh` runs the built binary
with `--export-icon` to emit an `.iconset`, then calls `iconutil`. No image files live in
the repo.

Stroke weight scales up below 32pt on purpose. At a fixed ratio the 16px render drops
under one pixel and the two squares smear into a blob.

## Testing reality

`CalSyncCore` is covered well: markers, reconciliation, guard classification, padding,
expiry, config validation. `CalSyncApp` has **no automated tests**, since EventKit wants
real calendars and TCC approval. After changing `CalendarStore`, verify by hand and read
`~/Library/Logs/CalSync/calsync.log`.

Watch the fixture trap in `ReconcilerTests`. Its `plan` helper pins `now` to a moment
before its fixture dates. Without that pin the fixtures drift into the past as real time
passes, every block quietly reclassifies as *expired*, and the guard tests stop testing
the guard.

One untested edge inherited from v1: EventKit's `occurrenceDate` for a moved occurrence
of a recurring series may report the original slot, which would produce an in place
update where cancel plus create belongs.

## Runtime state

* Settings live in `UserDefaults` under key `config`, a JSON encoded `AppConfig`.
  `AppConfig` has a custom `init(from:)` so settings written by an older build still
  decode once fields get added. Keep that when extending it.
* The log lives at `~/Library/Logs/CalSync/calsync.log`.
