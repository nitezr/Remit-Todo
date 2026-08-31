# Remit

A native macOS task manager: **Apple Reminders** as the backend, **Todoist** as the interface.

Your data lives in the real Reminders database via EventKit -- no separate store, no sync
service, no lock-in. Anything you do in Remit shows up in Reminders on your iPhone, and vice
versa. What Remit adds is the interface: views, sections, labels, filters, and a full
keyboard-driven workflow.

## Status: v0.1 scaffold

This is the first slice of a ground-up SwiftUI rewrite, replacing an earlier version built on
Raycast's Glaze/Electron toolchain (see `ROADMAP.md` for the full feature backlog carried over
from that build's 79 rounds of iteration). This scaffold has **not been compiled or run** --
it was written without access to Xcode or a Swift toolchain, so treat the first build in Xcode
as the real integration test. Open an issue-shaped note (or just tell me directly) about
whatever the compiler flags first.

What works in this slice:
- EventKit access request + live reminders/lists fetch (`RemindersService`)
- Reminders lists shown as projects in a sidebar; Inbox / Today / Upcoming smart views
- Quick add (plain text -> new reminder, no NLP parsing yet)
- Complete/uncomplete a task, arrow-key navigation between tasks
- A local metadata sidecar (`MetadataStore`) for the Remit-only concepts EventKit can't hold
  (sections, project emoji/color, favorites) -- present as a data layer, not yet wired into any
  view

What's explicitly not here yet: board/calendar layouts, drag-and-drop, the command palette,
labels, filters, templates, the MCP server, and the whole visual pass to actually match Todoist.
All of it is scoped in `ROADMAP.md`, grouped by priority and cross-referenced to the original
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

## Distribution plan

Not yet set up. The intent is: proper code signing with a Developer ID, notarization, DMG
builds attached to GitHub Releases, and Sparkle for in-app auto-updates -- so this can be
handed to other people, not just run locally. None of that is wired up yet; get the app working
first.
