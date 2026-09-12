# Architecture

Remit is a Swift Package (not an `.xcodeproj`): open `Package.swift` in Xcode, or use `swift build`
and `swift test` from Terminal.

```
Sources/Remit/                SwiftUI app
  RemitApp.swift              entry point
  Models/
    RemitTask.swift           value type; not an EKReminder
    RemitProject.swift        value type; not an EKCalendar (plus ListGroup)
    TaskSection.swift         a Reminders section
    Label.swift               ReminderTag -- a Reminders tag, identified by name
    Priority.swift            P1-P4 <-> EventKit's 0/1-4/5/6-9 scale
    TourContent.swift         the welcome tour's practice list
  Services/
    RemindersService.swift    the only file that imports EventKit; everything above it
                              works with RemitTask/RemitProject, never EKReminder/EKCalendar
    MetadataStore.swift       JSON sidecar in ~/Library/Application Support/Remit/ for
                              presentation only (emoji, order, favourites, filters, templates)
    StoreWatcher.swift        refreshes when Reminders' store changes underneath Remit
    DemoMode.swift            `--demo`: made-up data for screenshots and trying the app
  Views/                      sidebar, list/board/calendar layouts, quick add, details, tour
Sources/RemindersNative/      read-only SQLite reader for Reminders' tags, sections and groups
Sources/ReminderKitBridge/    writes for the same, through Apple's private ReminderKit framework
Sources/remit-cli/            JSON command-line tool over the same data
```

## Reminders' tags, sections and groups

EventKit has no API for tags, sections or list groups, so two modules go around it the way
[RemCTL](https://github.com/viticci/remctl) does: reads come straight from Reminders' own store,
and writes go through ReminderKit -- the framework Reminders.app itself uses -- so Reminders'
daemon still owns sync and schema and Remit never writes SQLite. EventKit identifiers are
ReminderKit identifiers, so the two join without a mapping table.

The trade-off is that ReminderKit is private. A macOS update can change it; the bridge checks
every selector before calling it and reports an error rather than crashing, but the feature can
still stop working until Remit is updated. It is also why Remit cannot ship on the App Store.

Reading the store needs Full Disk Access. Without it Remit still works, shows a banner saying what
is missing, and refuses tag and section edits rather than writing them from an empty starting point.
The grant is tied to the app's signature, so use `./setup-signing.sh` once for local builds -- an
ad-hoc signed build changes identity every time it is rebuilt and loses the grant.

## One source of truth for dates

`RemindersService` is the single seam between Remit and EventKit. An earlier build of this app
had Today/Upcoming counts drift from what Reminders.app showed, because date logic was duplicated
per view. Here `isDueToday` / `isOverdue` live once, on `RemitTask`, and every view filters
through them.

## Screenshots

`scripts/screenshots.sh` regenerates every image in `docs/images/` from demo mode. Nothing personal
can end up in them: demo mode never reads Reminders, and every name in its data is invented.
