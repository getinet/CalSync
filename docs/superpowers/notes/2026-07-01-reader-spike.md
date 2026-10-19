# Reader Spike Finding — recurrence expansion

**Date run:** 2026-07-14
**Question:** Does Calendar.app (via JXA `whose({startDate ...})`) return individual
occurrences of a recurring event, or only the master?

## Observed

Probe (`scratch/read-spike.js`) against a `CalSync Spike` iCloud calendar containing
one single event and one weekly recurring event, both starting the next day, over a
rolling 30-day window returned **2 rows**:

```
Spike single  | Wed Jul 15 2026 10:00:00 | <uid> | (none)
Spike weekly  | Wed Jul 15 2026 14:00:00 | <uid> | FREQ=WEEKLY;INTERVAL=1
```

**Conclusion: MASTER ONLY.** The weekly event appeared exactly once (with its base
recurrence rule), not as ~4–5 expanded weekly occurrences. The single event behaved
normally.

## Consequence

Calendar.app scripting exposes only the base `recurrence()` RRULE string — **not**
EXDATE/RDATE, and not detached/modified occurrences. A hand-rolled expander built from
the RRULE alone therefore cannot know which single occurrences were **cancelled or
moved**, and would mirror "phantom" occurrences of meetings that no longer exist. That
breaks the cancellation / full-sync semantics.

## Decision (approved 2026-07-14)

**Read via EventKit; write via Calendar.app.**

- EventKit's `enumerateEventsMatchingPredicate` / `eventsMatchingPredicate` returns
  individual occurrences with exceptions (cancellations/moves) already applied — correct
  by construction.
- EventKit viability confirmed from `osascript` JXA (`scratch/ek-probe.js`):
  `ObjC.import('EventKit')` loads; `EKEventStore` instantiates. Authorization status was
  **4 (write-only)**, so the Reader must request **full calendar access**
  (`requestFullAccessToEventsWithCompletion`) and spin the run loop until the async
  callback fires. This is one additional macOS permission prompt.
- The Writer stays on Calendar.app scripting because that is what dispatches email
  invitations (EventKit does not send invites).

### Identity mapping for EventKit-read instances
- Single event → `workUid = event.calendarItemExternalIdentifier` (stable external id),
  `isRecurring = false`, `occurrenceStartIso = null`.
- Recurring occurrence → `workUid = event.calendarItemExternalIdentifier` (series id),
  `isRecurring = true`, `occurrenceStartIso = ISO(event.occurrenceDate)`.

This feeds the existing marker scheme unchanged: single events get a time-independent
marker; recurring occurrences embed the occurrence start.
