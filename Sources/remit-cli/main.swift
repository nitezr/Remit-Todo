import EventKit
import Foundation

/// `remit` — a read/write CLI over the same Apple Reminders data the app uses.
///
/// This is a **separate executable**, not a server inside Remit.app. An embedded HTTP/MCP server
/// would put a listening socket and a request loop inside the UI process, where a crash or a hung
/// request takes the app down with it; a CLI is a process that starts, does one thing, and exits.
/// AI agents (Claude Code and anything else that can run a command) drive it by shelling out,
/// which covers ROADMAP.md's MCP goal without the app carrying that risk.
///
/// Output is JSON on stdout so callers can parse it; errors go to stderr with a non-zero exit.
///
/// Labels, sections, favourites and nesting are Remit-layer metadata and are read from the same
/// JSON file the app writes. This tool only ever *reads* that file -- the app owns writing it, so
/// the two can never fight over it.

// MARK: - Output

struct CLIError: Error { let message: String }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("remit: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func emit(_ value: Any) {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
        fail("could not encode output")
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

// MARK: - Store access

/// Built on first use rather than at startup. Constructing an EKEventStore reaches out to the
/// calendar daemon, which hangs in restricted environments -- `remit help` has no business
/// touching EventKit at all.
private var _store: EKEventStore?
var store: EKEventStore {
    if let _store { return _store }
    let created = EKEventStore()
    _store = created
    return created
}

func requestAccess() {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    var failure: Error?
    store.requestFullAccessToReminders { ok, error in
        granted = ok
        failure = error
        semaphore.signal()
    }
    semaphore.wait()
    if let failure { fail("reminders access failed: \(failure.localizedDescription)") }
    guard granted else {
        fail("reminders access denied. Grant it in System Settings > Privacy & Security > Reminders.")
    }
}

func fetchReminders(in calendars: [EKCalendar]) -> [EKReminder] {
    let semaphore = DispatchSemaphore(value: 0)
    var result: [EKReminder] = []
    store.fetchReminders(matching: store.predicateForReminders(in: calendars)) { reminders in
        result = reminders ?? []
        semaphore.signal()
    }
    semaphore.wait()
    return result
}

func calendar(named name: String) -> EKCalendar? {
    let all = store.calendars(for: .reminder)
    return all.first { $0.title.lowercased() == name.lowercased() }
        ?? all.first { $0.calendarIdentifier == name }
}

// MARK: - Remit metadata (read-only)

struct Metadata: Decodable {
    struct Label: Decodable { let id: String; let name: String }
    var labels: [Label] = []
    var labelAssignments: [String: [String]] = [:]
}

let metadata: Metadata = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let url = support.appendingPathComponent("Remit/metadata.json")
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(Metadata.self, from: data) else {
        return Metadata()
    }
    return decoded
}()

func labelNames(forTask id: String) -> [String] {
    let ids = metadata.labelAssignments[id] ?? []
    return ids.compactMap { labelID in metadata.labels.first { $0.id == labelID }?.name }
}

// MARK: - Serialisation

let isoFormatter = ISO8601DateFormatter()

func describe(_ reminder: EKReminder) -> [String: Any] {
    var payload: [String: Any] = [
        "id": reminder.calendarItemIdentifier,
        "title": reminder.title ?? "",
        "completed": reminder.isCompleted,
        "project": reminder.calendar?.title ?? "",
        "priority": reminder.priority,
        "labels": labelNames(forTask: reminder.calendarItemIdentifier),
    ]
    if let notes = reminder.notes { payload["notes"] = notes }
    if let components = reminder.dueDateComponents,
       let date = Calendar.current.date(from: components) {
        payload["due"] = isoFormatter.string(from: date)
        payload["hasTime"] = components.hour != nil
    }
    return payload
}

/// Accepts an ISO date, `today`, `tomorrow`, or `YYYY-MM-DD`.
func parseDue(_ raw: String) -> DateComponents? {
    let calendar = Calendar.current
    let lower = raw.lowercased()
    var date: Date?
    if lower == "today" {
        date = calendar.startOfDay(for: Date())
    } else if lower == "tomorrow" {
        date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
    } else if let parsed = isoFormatter.date(from: raw) {
        date = parsed
    } else {
        let plain = DateFormatter()
        plain.dateFormat = "yyyy-MM-dd"
        date = plain.date(from: raw)
    }
    guard let date else { return nil }
    return calendar.dateComponents([.year, .month, .day], from: date)
}

// MARK: - Commands

let usage = """
remit — command-line access to your Apple Reminders tasks.

USAGE
  remit projects
  remit list [--project <name>] [--due today|tomorrow|overdue] [--all]
  remit add <title> [--project <name>] [--due <today|tomorrow|YYYY-MM-DD>] [--priority 1-4] [--notes <text>]
  remit complete <task-id>
  remit delete <task-id>

Output is JSON. Task ids come from `remit list`.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}
arguments.removeFirst()

/// Reads `--name value` out of the remaining arguments.
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func hasFlag(_ name: String) -> Bool {
    arguments.contains("--\(name)")
}

switch command {
case "help", "--help", "-h":
    print(usage)

case "projects":
    requestAccess()
    let reminders = fetchReminders(in: store.calendars(for: .reminder))
    let payload = store.calendars(for: .reminder).map { calendar -> [String: Any] in
        [
            "id": calendar.calendarIdentifier,
            "title": calendar.title,
            "openTasks": reminders.filter { !$0.isCompleted && $0.calendar?.calendarIdentifier == calendar.calendarIdentifier }.count,
        ]
    }
    emit(payload)

case "list":
    requestAccess()
    let calendars: [EKCalendar]
    if let name = option("project") {
        guard let match = calendar(named: name) else { fail("no project named \(name)") }
        calendars = [match]
    } else {
        calendars = store.calendars(for: .reminder)
    }

    var reminders = fetchReminders(in: calendars)
    if !hasFlag("all") {
        reminders = reminders.filter { !$0.isCompleted }
    }

    if let due = option("due") {
        let today = Calendar.current.startOfDay(for: Date())
        reminders = reminders.filter { reminder in
            guard let components = reminder.dueDateComponents,
                  let date = Calendar.current.date(from: components) else { return false }
            let day = Calendar.current.startOfDay(for: date)
            switch due.lowercased() {
            case "today": return day == today
            case "tomorrow": return day == Calendar.current.date(byAdding: .day, value: 1, to: today)
            case "overdue": return day < today
            default: fail("unknown --due value: \(due)")
            }
        }
    }
    emit(reminders.map(describe))

case "add":
    guard let title = arguments.first, !title.hasPrefix("--") else { fail("add needs a title") }
    requestAccess()

    let target: EKCalendar?
    if let name = option("project") {
        target = calendar(named: name)
        if target == nil { fail("no project named \(name)") }
    } else {
        target = store.defaultCalendarForNewReminders()
    }
    guard let target else { fail("no default Reminders list available") }

    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    reminder.calendar = target
    reminder.notes = option("notes")

    if let due = option("due") {
        guard let components = parseDue(due) else { fail("could not parse --due \(due)") }
        reminder.dueDateComponents = components
    }
    if let priority = option("priority") {
        guard let level = Int(priority), (1...4).contains(level) else { fail("--priority must be 1-4") }
        reminder.priority = [1, 5, 9, 0][level - 1]
    }

    do {
        try store.save(reminder, commit: true)
    } catch {
        fail("could not save: \(error.localizedDescription)")
    }
    emit(describe(reminder))

case "complete", "delete":
    guard let id = arguments.first else { fail("\(command) needs a task id") }
    requestAccess()
    guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
        fail("no task with id \(id)")
    }
    do {
        if command == "complete" {
            reminder.isCompleted = true
            reminder.completionDate = Date()
            try store.save(reminder, commit: true)
        } else {
            try store.remove(reminder, commit: true)
        }
    } catch {
        fail("could not \(command): \(error.localizedDescription)")
    }
    emit(["ok": true, "id": id, "action": command])

default:
    fail("unknown command \(command)\n\n\(usage)")
}
