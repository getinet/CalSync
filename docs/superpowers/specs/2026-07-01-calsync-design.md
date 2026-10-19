# CalSync — Design

**Date:** 2026-07-01
**Status:** Approved for planning

## Purpose

Surface work events on a personal calendar that lives on a **different account/device** — one this Mac's Calendar app cannot write to directly. CalSync mirrors events from one work calendar onto a dedicated local calendar whose only attendee is the user's personal email. Calendar.app then dispatches invitations (and updates/cancellations) that carry the events to the personal device.

## Constraints & decisions

| Decision | Choice |
| --- | --- |
| Personal calendar location | Different account/device — reachable only via email invitation |
| Implementation | **Approach B**: JXA (`osascript -l JavaScript`) driving Calendar.app |
| Detail level | **Title + time only** — drop location, notes, and all original attendees |
| Sync model | **Full sync** — create, update, and cancel |
| Cadence | **Both** — launchd schedule + manual run (same script) |
| Window | Rolling **now → +30 days** |
| Recurring events | **Expand to instances** — one copy + invite per occurrence in window |
| State | **Self-describing copies** — identity encoded in the copy's `url`; no external state file |
| Mass-cancel guard | Pause cancellations if **> 25%** of existing copies would be cancelled in one run |

## Runtime picture

```
launchd (schedule)  ─┐
                     ├─►  osascript -l JavaScript  ──Apple events──►  Calendar.app  ──►  invite email ──► personal calendar
you (manual run)    ─┘
```

`osascript` (built into macOS) is the interpreter; Calendar.app is driven via Apple events and is the component that actually reads/writes events and sends invitations.

## Components

Each component has one purpose, a defined interface, and can be understood in isolation.

### 1. Reader (adapter over EventKit)
- **Does:** Reads the named work calendar and expands the `now → +30 day` window into concrete event instances.
- **Why EventKit (not Calendar.app scripting):** the Task 5 spike found that Calendar.app's `whose(...)` query returns only the *master* recurring event plus its base RRULE — not expanded occurrences, and with no visibility into cancelled/moved single occurrences. EventKit's occurrence enumeration expands the series *and* applies exceptions, so it is the only read path that won't mirror phantom occurrences. See `docs/superpowers/notes/2026-07-01-reader-spike.md`.
- **Per instance:** title, start, end, all-day flag, work `uid`, is-recurring flag, and (for recurring) the occurrence start. Identity: `workUid = calendarItemExternalIdentifier`; recurring occurrences use `occurrenceDate` as the occurrence start.
- **Depends on:** EventKit, **full calendar access** (the Reader requests it via `requestFullAccessToEventsWithCompletion` and spins the run loop until the async callback fires).
- **Hard rule:** if the named work calendar is not found this run, **abort the entire run** — never treat a missing/empty calendar as "everything was cancelled."

### 2. Reconciler (pure function — the heart)
- **Does:** Given `(workInstances, existingCopies)` as plain data, returns `{ toCreate, toUpdate, toCancel, guardTripped }`.
- **Depends on:** nothing — no Calendar.app, no I/O. Fully unit-testable.
- **Owns:** all sync logic and the mass-cancel guard.

### 3. Writer (adapter over Calendar.app)
- **Does:** Applies the reconciler's plan — create / update / delete copies in the dedicated calendar.
- **Side effect:** because each copy carries the personal email as an attendee, Calendar.app emits invite / updated-invite / cancellation emails.
- **Depends on:** Calendar.app, dedicated calendar on an invite-capable account.
- **Single-attendee guardrail:** before writing any create or update, the Writer asserts the copy has **exactly one attendee, and it equals the configured personal email**. If the check fails — zero, more than one, or a non-matching address — the Writer **refuses to write that event**, logs it, and moves on. This is a secondary defense against ever inviting a coworker, independent of the copy-construction logic.

### 4. Runner (entry point)
- **Does:** Wires Reader → Reconciler → Writer; writes a run summary to the log.
- **Flags:** `--dry-run` logs the plan and sends nothing.

### 5. Scheduling
- A launchd LaunchAgent plist provides the automatic cadence.
- The same script is the manual command.

## Copy contents (title + time only)

| Field | Value |
| --- | --- |
| `summary` | work event title |
| `start` / `end` | copied, including all-day flag |
| attendees | **personal email only** |
| `url` | identity marker (see below) |
| location, notes, original attendees | **dropped** |

Dropping original attendees is a hard requirement — the script must never re-invite the user's coworkers.

## Identity / matching (self-describing copies)

The copy's `url` field encodes its source:

- Single event: `x-calsync://<work_uid>`
- Recurring occurrence: `x-calsync://<work_uid>/<occurrence_start_iso>`

Each run derives all state by reading both calendars and parsing these URLs. There is **no external state file** — the design is idempotent and self-healing.

## Sync behavior (full sync)

- **Skip self-invited events** — if a source work event's guest list already includes the configured personal email, the Reader drops it from scope (the user is invited directly, so mirroring would duplicate it). Source attendee emails are read only for this decision and never stored or copied. Composes with cancel: if the personal account is added to an already-mirrored event, it leaves scope on the next run and its mirror copy is cancelled (subject to the mass-cancel guard).
- **Skip explicitly-excluded events** — a manual opt-out: if a source event's title contains the 🚫 marker (`EXCLUDE_MARKER`), the Reader drops it from scope. Like the self-invited skip, adding 🚫 to an already-mirrored event's title cancels its mirror copy on the next run.
- **Create** — a work instance with no matching copy → create copy + send invite.
- **Update (single events)** — if title / start / end changed, update the copy in place → Calendar.app sends an updated invite (one clean email).
- **Recurring moved occurrence** — because the occurrence start is part of the identity key, a moved instance is handled as **cancel-old + create-new** (two emails). Accepted tradeoff: recurring exceptions are rare.
- **Cancel** — a copy whose source instance is gone → delete → cancellation email.

## Safety

- **Calendar-not-found → abort.** No changes made.
- **Mass-cancel guard (> 25%).** If a single run would cancel more than a quarter of existing copies, skip the cancellations, log a warning, and leave them for the next run to confirm. Guards against a partial/offline work-calendar read wiping the mirror.
- **Single-attendee guardrail.** Enforced in the Writer (see Component 3): every create/update must have exactly one attendee equal to the configured personal email, or the event is refused and logged. Secondary defense so no coworker is ever invited even if the copy logic has a bug.
- **`--dry-run`.** Prints the full plan and sends nothing. The safe way to preview — especially the first run, which sends a burst of invites for everything already in the window.

## Error handling & logging

- Every run appends a timestamped summary to `~/.calsync/calsync.log`:
  `created N, updated M, cancelled K, guard: ok|tripped`.
- Per-event failures are logged and do **not** abort the run.
- Startup checks: work calendar found; warn if the dedicated calendar is not on an invite-capable (iCloud/Exchange) account.

## Testing

- **Reconciler (unit tests, no Calendar.app):** new / update / cancel / no-op; guard trips at > 25%; recurring move → cancel+create; calendar-not-found → abort. This is where most of the risk lives.
- **Single-attendee guardrail (unit test):** the assertion is extracted as a pure predicate so it can be tested directly — passes for exactly one matching personal email; refuses on zero attendees, more than one, or a non-matching address.
- **Reader / Writer (manual spike):** confirm that a copy with the personal email as attendee produces an invitation that actually lands on the personal calendar. This de-risks the single assumption behind Approach B before the rest is built.

## Prerequisites (strings attached)

- Dedicated calendar on an **iCloud or Exchange** account (a local "On My Mac" calendar cannot send invitations).
- **Scheduled runs use a compiled `.app` bundle**, not a plain `osascript` LaunchAgent. On modern macOS a background `osascript` LaunchAgent cannot obtain calendar access (the access request can't prompt and hangs). The installer compiles CalSync into a signed `.app` with its own TCC identity and the required `NSCalendarsFullAccessUsageDescription` / `NSAppleEventsUsageDescription` strings; the user runs it once to approve the Calendar + Automation prompts, after which the hourly LaunchAgent inherits the grant.
- The runnable is staged in `~/.calsync/` (outside `~/Documents`) so it never triggers the Documents-folder TCC prompt.
- Re-running `install.sh` recompiles/re-signs the app (new code hash), so the one-time calendar grant must be re-approved after each re-install.
- Mac **awake and logged in** for scheduled runs (a LaunchAgent, not a LaunchDaemon — does not run at the login screen or before login).

## Known untested edges (verify before relying on)

- **Moved single occurrence of a recurring series:** `occurrenceStartIso` derives from EventKit's `occurrenceDate`, which for a detached/modified occurrence may report the *original* slot. If so, a moved occurrence would update in place rather than cancel+create. The reconciler logic is unit-tested; the real EventKit value for a moved occurrence was not. Verify by dragging one occurrence and inspecting a `--dry-run` plan.
- **All-day events:** now exercised in production. Fixed a duplication bug where all-day (and any in-progress) events were re-created every run because `getExistingCopies` used a `startDate`-in-window filter while the reader uses overlap — the existing copy was invisible to the copy lookup once the event's start was earlier than "now". `getExistingCopies` now uses an overlap window matching the reader, and `reconcile` cancels redundant same-marker duplicate copies (guard-exempt) to converge. Date fidelity (correct day on the personal calendar) verified for an all-day event in the user's timezone.
- **Dedicated-calendar sharing (ACL):** the attendee guardrail governs event attendees, not calendar-level sharing. If the dedicated calendar itself were shared with others, that is a channel the guardrail cannot see. Keep the mirror calendar unshared.

## Out of scope (YAGNI)

- Two-way sync (personal → work).
- Copying location / notes / attendees.
- Chasing reschedules of individual recurring occurrences as in-place updates (handled as cancel+create instead).
- Self-healing a manually-corrupted copy. The dedicated calendar is machine-owned and should not be hand-edited; the single-attendee guardrail enforces integrity at write time, but `reconcile`'s `fieldsDiffer` compares only title/time, so a copy whose attendee list was externally tampered with is not automatically re-checked unless the source event's title/time also changes. Accepted limitation.
- Any GUI.
