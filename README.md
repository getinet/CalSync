# CalSync

Two calendars. One of you. CalSync stops a company calendar and a client calendar from
booking the same hour twice, and neither side learns anything about the other beyond
"occupied".

When an event exists on one calendar, CalSync writes a block titled **Busy** on the
other. Only times travel between them. Titles, notes, locations, and guests stay home.

## Install

Requires macOS 14 or later and the Swift toolchain that ships with Xcode.

```bash
./build.sh --install
```

That builds the app, copies it into `/Applications`, and launches it. A small mark of
two overlapping squares appears in your menu bar.

macOS asks for full calendar access on first launch. CalSync reads nothing without it.
Settings opens on its own so you can pick your calendars.

## Setup

Pick the calendar each side reads. With two calendars that is the whole job, because the
destinations fill themselves in and point at the opposite calendar.

The company side reads your company calendar and writes Busy blocks to your client
calendar. The client side does the mirror image.

Blocks then sit alongside real events in each calendar. To keep them separate, press
**New…** beside a destination and CalSync creates a dedicated Busy calendar in whichever
account you choose. Some account types refuse to create calendars from software. When
that happens, make the calendar in Calendar.app and pick it from the list.

### This does not loop

A fair thing to worry about, since each calendar writes into the other. CalSync declines
to treat an event as a source when it carries CalSync's marker, and again when its title
matches your block title exactly. Blocks never make the return trip.

One consequence worth knowing: a real event you title exactly "Busy" stays home too.

Two arrangements get refused. Both sides writing into one calendar would have each side
deleting the other's work every run. A calendar set as its own destination would fill
with Busy copies of its own events. Save stays dim in either case and the reason appears
at the bottom of the window.

## How it behaves

* Only events that have yet to start are mirrored. A block vanishes the moment its
  meeting begins. Worth knowing what that costs: during the meeting your other calendar
  reads as free, so a colleague can book over you mid call.
* All day events are ignored completely.
* Every block gets a 5 minute buffer on each side, so back to back bookings across two
  accounts leave you room to breathe. Adjustable down to zero.
* Rescheduling an event moves its block. Deleting an event removes its block.
* Syncing happens within seconds of you editing either calendar, on a timer, and on wake.

### Skipping an event

Put 🚫 anywhere in an event's title. CalSync leaves it alone, and removes its block if
one already exists.

## Safety

CalSync touches only events it created. Each one carries a hidden `x-calsync://` marker
in the event URL field. Everything else in your calendars is none of its business.

If a single run would delete more than 25% of the future blocks it manages, it deletes
none of them and tells you instead. That protects your calendars from a sync that failed
halfway through. Blocks that aged out normally are exempt, so ordinary cleanup keeps
flowing.

## Everyday use

Everything lives behind the menu bar icon:

* **Sync Now** for an immediate run
* **Open Log** to see what happened
* **Open at Login** to start automatically
* **Settings…** to change calendars and options

The log lives at `~/Library/Logs/CalSync/calsync.log`.

## Limitations

* CalSync works while your Mac is awake and logged in. Nothing syncs from your phone,
  since your Mac is the one doing the work.
* The app is ad hoc signed, which is fine on your own machine. Sharing it with a
  colleague calls for an Apple Developer ID, or they get to right click and choose Open
  past Gatekeeper.
* A meeting that already lives on both calendars, because you were invited at both
  addresses, collects a redundant Busy block on top of the real event. Harmless, mildly
  cluttered.
* Rebuilding changes the app signature, so macOS may ask for calendar permission again
  after an update.

## Credits

Built by [Eric Kramp](https://github.com/EricKramp) and
[Mekuria Getinet](https://github.com/getinet).

## Development

```bash
swift test
```

```bash
./build.sh
```

`Sources/CalSyncCore` holds the pure sync logic and carries the unit tests.
`Sources/CalSyncApp` holds the EventKit and AppKit layer. `CLAUDE.md` has the
architecture notes and the invariants that need to stay where they are.
