# CalSync — Shareable Setup (design / hand-off brief)

**Date:** 2026-07-20
**Status:** Design only — NOT implemented. Written for another agent (or a colleague's agent) to analyze, plan, and adapt.

## Purpose

Let a Terminal-comfortable colleague install CalSync on their own Mac with their own
calendar and email addresses — without editing code, and selecting their work calendar
from a menu instead of hand-typing exact names. No change to the sync engine.

## Read this first: current state of the repo

CalSync already works end-to-end and runs live on the original author's machine. Key
facts an implementing agent needs:

- **Language / runtime:** macOS JXA, run by `osascript -l JavaScript`. Zero dependencies
  (no Node/npm). Pure logic in `src/lib.js`; EventKit reader + Calendar.app writer +
  logging in `src/adapter.js`; runner in `src/main.js`. `build.sh` concatenates the three
  into `dist/calsync.js`.
- **Scheduling:** `install/install.sh` compiles `dist/calsync.js` into a signed
  `~/.calsync/CalSync.app` (its own TCC identity, with `NSCalendarsFullAccessUsageDescription`
  + `NSAppleEventsUsageDescription`), stages the runnable in `~/.calsync/` (outside
  `~/Documents` to avoid that folder's TCC prompt), and loads a `StartCalendarInterval`
  LaunchAgent (`install/net.beezwax.calsync.plist`, top of every hour).
- **Config:** `~/.calsync/config.json` (NOT in git). Fields:
  `workCalendarName`, `workCalendarAccount`, `dedicatedCalendarName`, `personalEmail`,
  `organizerEmail`, `windowDays` (default 30), `cancelThreshold` (default 0.25).
- **Reads exactly one calendar today:** the EventKit query is scoped to the single
  `workCalendarName` + `workCalendarAccount`; nothing else is read. Same-name calendars
  across accounts are disambiguated by `workCalendarAccount` (an EKSource title, e.g.
  "Exchange"). See `getWorkInstances` in `src/adapter.js`.
- **Skips:** events whose title contains `🚫` (`EXCLUDE_MARKER`), and events where
  `personalEmail` is already a guest. See `titleExcluded` / `containsEmail` in `src/lib.js`.
- **Safety guardrail:** copies carry exactly the personal email + the calendar's
  auto-added organizer (`organizerEmail`); any third party fails closed. See
  `attendeesWithinAllowed` in `src/lib.js`.
- **Design + findings context:** `docs/superpowers/specs/2026-07-01-calsync-design.md`,
  `docs/superpowers/notes/2026-07-01-{reader,invite}-spike.md`.

## Goal

A guided, interactive setup so the colleague runs one script, picks their calendar from a
list, and ends with a working hourly sync — plus a README.

## Non-goals

- No `.pkg`/`.app` double-click installer, no Apple Developer ID notarization.
- No change to the reconcile/reader/writer engine (only new setup tooling + docs).
- No multi-calendar support — one selected calendar remains the model.

## Components to build

### 1. `list-calendars` helper (JXA)
Prints every readable calendar as a numbered list: **index, name, account (EKSource
title), writable flag**. Basis for the picker. EventKit reference already in
`src/adapter.js` (`store.calendarsForEntityType`, `c.title`, `c.source.title`,
`c.allowsContentModifications`). Can live as a standalone `install/list-calendars.js`
or a function reused by `setup.sh`.

### 2. `setup.sh` (interactive, new)
Ordered flow:
1. Show the numbered calendar list; read a number → set `workCalendarName` +
   `workCalendarAccount` from the chosen calendar.
2. Show the list again (or filter to writable); read a number → set
   `dedicatedCalendarName` (the mirror calendar, which the colleague created first per
   the README).
3. Prompt for `personalEmail` (validate non-empty; basic email shape).
4. **Probe auto-detect `organizerEmail`:** create a throwaway event in the mirror with
   `personalEmail` as the sole attendee, read back the address the account auto-adds as
   organizer/participant (the non-personal one), capture it, delete the probe. If
   detection yields nothing, fall back to prompting. (Sends one invite+cancel to the
   personal address during setup — documented and expected.)
5. Write `~/.calsync/config.json` (preserve existing file if re-running? — see open
   questions). Then run `build.sh`, compile the app, load the LaunchAgent (reuse
   `install/install.sh` logic — consider refactoring shared steps into it).
6. Print the final one-time step: `open ~/.calsync/CalSync.app` to grant the app's own
   calendar access.

### 3. `README.md`
- Prerequisites: macOS; create an empty **mirror** calendar (e.g. "CalSync Mirror") in an
  invite-capable **iCloud or Exchange** account first.
- Run `./setup.sh`, follow prompts, approve the calendar permission prompts (osascript
  during setup, then the app once at the end).
- Operating notes: manual dry-run (`osascript -l JavaScript ~/.calsync/calsync.js
  --dry-run`), watch log (`tail -f ~/.calsync/calsync.log`), change cadence (edit
  `StartCalendarInterval` in the LaunchAgent plist), stop (`launchctl unload …`).
- Opt-out controls: add `🚫` to a work event's title, or invite your personal address
  directly to a work event.
- Privacy statement: CalSync reads only the single selected work calendar's events (plus
  the mirror it owns); setup reads calendar names to render the picker but never other
  calendars' event contents.

## The "only 1 selected calendar" guarantee

Already true in the engine — reaffirm and document. The picker makes selection safe and
disambiguates same-named calendars by account. No code change needed beyond exposing the
selection in `setup.sh`; the scoped EventKit predicate in `getWorkInstances` is the
enforcement.

## TCC ordering (important subtlety)

Two separate TCC identities need calendar access:
- **`osascript`** — used by `setup.sh` for listing + the probe. First use prompts the
  colleague inline (Terminal can show the prompt).
- **`CalSync.app`** — used by the scheduled LaunchAgent. Has its own identity; granted by
  the final `open …CalSync.app` step. Re-running `install.sh`/`setup.sh` recompiles the
  app (new code signature) and requires re-approving this grant.

A background LaunchAgent using plain `osascript` (not the app) CANNOT obtain calendar
access — it hangs on the un-promptable request. This is why the app bundle exists; do not
"simplify" the scheduler back to plain osascript.

## Distribution hygiene (do before sharing)

- Dev docs under `docs/superpowers/` previously embedded the original author's real
  emails; these have been redacted to placeholders (`you@icloud.com` / `owner@icloud.com`).
  If re-adding examples, keep them as placeholders, or exclude `docs/superpowers/` from
  the distributed bundle.
- The live `~/.calsync/config.json` is outside git and is never shared.
- `Label`/plist id `net.beezwax.calsync` is fine to keep (it's just a launchd label).

## Config schema (unchanged; setup fills it)

```json
{
  "workCalendarName": "<picked>",
  "workCalendarAccount": "<picked account / EKSource title>",
  "dedicatedCalendarName": "<picked mirror calendar>",
  "personalEmail": "<prompted>",
  "organizerEmail": "<probe-detected, or prompted fallback>",
  "windowDays": 30,
  "cancelThreshold": 0.25
}
```

## Error handling

- Selection: reject out-of-range / non-numeric input; re-prompt.
- Email: reject empty / obviously malformed; re-prompt.
- Probe: on failure (no organizer detected, or Calendar automation denied), log a clear
  message and fall back to prompting for `organizerEmail`; ensure the probe event is
  deleted even on error.
- Mirror not found / not writable: abort with a clear message pointing at the README
  prerequisite.

## Testing

- Engine logic is already covered by `tests/lib.test.js` (92 checks) — unaffected.
- `setup.sh` is glue; make `list-calendars` and the probe individually runnable and
  exercise them on a real Mac before handing off. The colleague's first real run is the
  integration test; a `--dry-run` after setup should show a sane plan before any live
  invites.

## Open questions for the implementing agent / colleague

1. Re-run behavior: should `setup.sh` overwrite an existing `~/.calsync/config.json` or
   offer to edit individual fields?
2. Should `setup.sh` offer to create the mirror calendar via EventKit instead of
   requiring manual pre-creation? (EventKit can create calendars, but choosing the account
   adds complexity.)
3. Naming: keep `net.beezwax.calsync` or parameterize the label per-org?
4. Should cadence/window be prompted in setup, or left as defaults with README guidance?
