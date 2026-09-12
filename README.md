# Remit

A native macOS task manager: **Apple Reminders** as the backend, **Todoist** as the interface.

Your data lives in the real Reminders database -- no separate store, no sync service, no lock-in.
Anything you do in Remit shows up in Reminders on your iPhone, and vice versa, **including tags,
sections and list groups**: those are Reminders' own, read and written in place rather than
copied into a Remit-side system. What Remit adds is the interface: views, filters, templates,
and a full keyboard-driven workflow.

## Status: v0.3, running

A ground-up SwiftUI rewrite, replacing an earlier version built on Raycast's Glaze/Electron
toolchain (see `ROADMAP.md` for the full feature backlog carried over from that build's 79
rounds of iteration). It builds, runs, and is packaged as a DMG.

What works:
- EventKit read/write: Reminders lists as projects, reminders as tasks, live refresh
- Inbox / Today / Upcoming smart views, plus per-project views
- Three layouts everywhere -- List, Board (kanban), Calendar (day/3-day/week) -- each view
  remembering its own layout, grouping, sorting and filters
- Quick add with natural-language parsing, and `#project` / `@tag` autocomplete
- Apple Reminders' native tags, sections and list groups -- the same ones Reminders.app shows
- Saved filters, project templates
- Sidebar with Reminders groups, favourites, emoji and live counts
- Command palette (⌘K), settings window, keyboard shortcuts, task detail peek
- `remit-cli`, a separate binary for automation
- A welcome tour on first launch (Help → Welcome Tour) that explains both permissions and can add
  a practice list to Reminders

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
    TaskSection.swift         a Reminders section
    Label.swift               ReminderTag -- a Reminders tag, identified by name
    Priority.swift            Todoist P1-P4 <-> EventKit's 0/1-4/5/6-9 scale
  Services/
    RemindersService.swift    the only file that imports EventKit; everything above it
                               works with RemitTask/RemitProject, never EKReminder/EKCalendar
    MetadataStore.swift       JSON sidecar in ~/Library/Application Support/Remit/ for
                               presentation only (emoji, order, favourites, filters,
                               templates) -- deleting it loses no Reminders data
    StoreWatcher.swift        refreshes when Reminders' store changes underneath Remit
  Views/
    ContentView.swift, SidebarView.swift, TaskListView.swift, TaskRowView.swift,
    QuickAddView.swift, Color+Hex.swift
Sources/RemindersNative/      read-only SQLite reader for Reminders' tags, sections and groups
Sources/ReminderKitBridge/    writes for the same, through Apple's private ReminderKit framework
```

EventKit has no API for tags, sections or list groups, so those two modules go around it the way
[RemCTL](https://github.com/viticci/remctl) does: reads come straight from Reminders' own store,
and writes go through ReminderKit -- the framework Reminders.app itself uses -- so Reminders'
daemon still owns sync and schema and Remit never writes SQLite. EventKit identifiers are
ReminderKit identifiers, so the two join without a mapping table.

The trade-off is that ReminderKit is private. A macOS update can change it; the bridge checks
every selector before calling it and reports an error rather than crashing, but the feature can
still stop working until Remit is updated. It is also why Remit cannot ship on the App Store.

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

Tags, sections and groups also need **Full Disk Access**, because Reminders' store sits in a
protected group container. macOS has no prompt for that one: add Remit under System Settings ›
Privacy & Security › Full Disk Access, then reopen it. Until then Remit works as before, shows a
banner saying what is missing, and refuses tag and section edits rather than writing them blind.
The grant is tied to the app's signature, so use `./setup-signing.sh` once -- an ad-hoc signed
build changes identity every time it is rebuilt and loses the grant.

## Roadmap

See `ROADMAP.md` for the full backlog, organized P0 (core loop) through P2 (nice-to-have),
distilled from the previous build's complete prompt history.

## Install

Download the DMG from [Releases](https://github.com/niteshrathore/Remit-Todo/releases), open
it, and drag Remit to Applications. Or build one yourself:

```
./release.sh 0.3.0 --install
```

**Ad-hoc signed, not notarized.** A DMG you build runs fine on the machine that built it. One
you *download* is quarantined by macOS until you right-click Remit and choose Open, or run
`xattr -dr com.apple.quarantine /Applications/Remit.app`. Fixing that properly needs a paid
Apple Developer ID; `release.sh` switches to a hardened-runtime Developer ID signature
automatically once one is present. See `CONTRIBUTING.md`.

Still to come: notarization, and Sparkle for in-app auto-updates.

### Uninstall

```
./uninstall.sh
```

Quits Remit, moves the app, its settings file and its preferences to the Trash, and resets its
Reminders and Full Disk Access permissions, so the next install starts from the welcome tour again.
Your tasks, lists, tags and sections live in Apple Reminders and are not touched.

## Your data

Remit is a view over Apple Reminders and has never stored a task or a list. Tasks, lists, due
dates, priorities, tags, sections and list groups live in Apple Reminders and sync through iCloud
like always.

The only thing Remit keeps of its own is presentation Reminders has nowhere to put -- saved
filters, templates, project emoji, sidebar order, favourites -- in
`~/Library/Application Support/Remit/metadata.json`. Deleting that file costs you none of your
tasks, tags or sections. (Before v0.3 Remit kept its own labels, sections and nesting there too;
those are dropped from the file on the first save after upgrading.)

That file is defended: every write keeps the previous copy as `metadata.backup.json`, a file
that won't decode is moved aside rather than overwritten and the backup restored, and anything
unusual is reported in a banner instead of being swallowed. Adding a field to the format cannot
invalidate an older file. `CONTRIBUTING.md` has the details and the backup command.

## Development

`./run.sh` to build and launch, `swift test` for the suite, `git tag vX.Y.Z && git push --tags`
to cut a release. CI builds and tests every push and smoke-tests the DMG. See
`CONTRIBUTING.md`.

## License

MIT — see [LICENSE](LICENSE).
