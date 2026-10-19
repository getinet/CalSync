# Invite Spike Finding — Approach B go/no-go

**Date run:** 2026-07-14/15
**Question:** Does a mirrored copy carrying the personal email as attendee actually
produce an invitation that lands on the personal calendar (a different account/device)?

## Result: ✅ CONFIRMED — Approach B works.

Live run against `CalSync Spike` (test work calendar) → `CalSync Mirror` (iCloud) with
`personalEmail = you@icloud.com` (author's real address redacted):

- `RUN created=6 updated=0 cancelled=0 failed=0 guard=ok` — 6 occurrences (1 single +
  5 weekly) created in the mirror.
- Invitations arrived on the personal device and, when accepted, landed on the personal
  calendar showing **title + time only** — no location, notes, or coworker attendees.
- **Idempotency confirmed:** an immediate re-run produced `created=0 updated=0
  cancelled=0` — the self-describing `url` markers round-trip through Calendar.app, so
  copies are recognized and never duplicated.

## Key finding: iCloud auto-adds the calendar owner as organizer

When any attendee is added to an event on the mirror calendar, iCloud automatically
adds the mirror calendar's **owner** (e.g. `owner@icloud.com`, the user's own
work-linked iCloud — real address redacted) as a second participant. The original strict single-attendee
read-back guardrail therefore refused **every** create (failing safe: `created=0`, all
events deleted, no coworker ever at risk).

**Resolution:** the read-back guardrail was generalized to `attendeesWithinAllowed`,
which permits exactly `{personalEmail, organizerEmail}` and still fails closed on any
third-party address. `organizerEmail` is a config field. See commit 787255f.

## Notes
- The first (pre-fix) run may have emitted brief invite+cancellation pairs to the
  personal address as events were created then deleted by the guardrail — harmless
  (all to the user's own address).
- Switching `workCalendarName` from `CalSync Spike` to the real work calendar will make
  all 6 spike copies "disappear" → they'd be cancelled, but 6/6 = 100% > 25% trips the
  mass-cancel guard, so the first real-calendar run will pause cancellations (safe).
  Clear the mirror manually or run once to let the guard pass on a later run.
