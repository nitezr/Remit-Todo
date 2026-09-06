# Remit

A native macOS task manager: **Apple Reminders** as the backend, **Todoist** as the interface.

Your data lives in the real Reminders database via EventKit -- no separate store, no sync
service, no lock-in. Anything you do in Remit shows up in Reminders on your iPhone, and vice
versa. What Remit adds is the interface: views, sections, labels, filters, and a full
keyboard-driven workflow.

## Status: v0.2, running

A ground-up SwiftUI rewrite, replacing an earlier version built on Raycast's Glaze/Electron
toolchain (see `ROADMAP.md` for the full feature backlog carried over from that build's 79
rounds of iteration). It builds, runs, and is packaged as a DMG.

What works:
- EventKit read/write: Reminders lists as projects, reminders as tasks, live refresh
- Inbox / Today / Upcoming smart views, plus per-project views
- Three layouts everywhere -- List, Board (kanban), Calendar (day/3-day/week) -- each view
  remembering its own layout, grouping, sorting and filters
- Quick add with natural-language parsing, and `#project` / `@label` autocomplete
- Sections, labels, saved filters, project templates
- Sidebar with nesting, favourites, emoji and live counts
- Command palette (⌘K), settings window, keyboard shortcuts, task detail peek
- `remit-cli`, a separate binary for automation

Not there yet: drag-and-drop is partial, the MCP server, and the visual pass to fully match
Todoist. All scoped in `ROADMAP.md`, grouped by priority and cross-referenced to the original
prompt log.

## Architecture

```
Sources/Remit/
  RemitApp.swift              entry point, requests Reminders access on launch
  Models/
    RemitTask.swift           value type; not an EKReminder
    RemitProject.swift        value type; not an EKCalendar
    TaskSection.swift         Remit-only, no EventKit equivalent
    Priority.swift            Todoist P1-P4 <-> EventKit's 0/1-4/5/6-9 scale
  Services/
    RemindersService.swift    the only file that imports EventKit; everything above it
                               works with RemitTask/RemitProject, never EKReminder/EKCalendar
    MetadataStore.swift       JSON sidecar in ~/Library/Application Support/Remit/,
                               keyed by EKCalendar/EKReminder identifiers -- deleting it
                               loses no real Reminders data
  Views/
    ContentView.swift, SidebarView.swift, TaskListView.swift, TaskRowView.swift,
    QuickAddView.swift, Color+Hex.swift
```

The split matters: `RemindersService` is the single seam between Remit and EventKit. A prior
build of this app (see `ROADMAP.md` "Known traps") had Today/Upcoming counts drift from what
Reminders.app itself showed, because date logic was duplicated per-view. Here, `isDueToday` /
`isOverdue` live once, on `RemitTask`, and every view filters through them.

## Building

This is a Swift Package, not an `.xcodeproj` -- open `Package.swift` directly in Xcode
(File > Open), or from Terminal:

```
swift build
swift run
```

Requires macOS 14+ and Xcode 15+. First launch prompts for Reminders access
(`NSRemindersFullAccessUsageDescription` in `Sources/Remit/Supporting/Info.plist`).

## Roadmap

See `ROADMAP.md` for the full backlog, organized P0 (core loop) through P2 (nice-to-have),
distilled from the previous build's complete prompt history.

## Install

Download the DMG from [Releases](https://github.com/niteshrathore/Remit-Todo/releases), open
it, and drag Remit to Applications. Or build one yourself:

```
./release.sh 0.2.0 --install
```

**Ad-hoc signed, not notarized.** A DMG you build runs fine on the machine that built it. One
you *download* is quarantined by macOS until you right-click Remit and choose Open, or run
`xattr -dr com.apple.quarantine /Applications/Remit.app`. Fixing that properly needs a paid
Apple Developer ID; `release.sh` switches to a hardened-runtime Developer ID signature
automatically once one is present. See `CONTRIBUTING.md`.

Still to come: notarization, and Sparkle for in-app auto-updates.

## Your data

Remit is a view over Apple Reminders and has never stored a task or a list. Tasks, lists, due
dates, priorities and tags live in Apple Reminders and sync through iCloud like always.

The only thing Remit keeps of its own is the decoration layer EventKit has nowhere to put --
sections, labels, saved filters, templates, project emoji, nesting, favourites -- in
`~/Library/Application Support/Remit/metadata.json`. Deleting that file costs you none of your
actual tasks.

That file is defended: every write keeps the previous copy as `metadata.backup.json`, a file
that won't decode is moved aside rather than overwritten and the backup restored, and anything
unusual is reported in a banner instead of being swallowed. Adding a field to the format cannot
invalidate an older file. `CONTRIBUTING.md` has the details and the backup command.

## Development

`./run.sh` to build and launch, `swift test` for the suite, `git tag vX.Y.Z && git push --tags`
to cut a release. CI builds and tests every push and smoke-tests the DMG. See
`CONTRIBUTING.md`.
