import AppKit
import EventKit
import Foundation

enum RemindersServiceError: LocalizedError {
    case projectNotFound
    case taskNotFound
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .projectNotFound: return "That project could not be found in Reminders."
        case .taskNotFound: return "That task could not be found in Reminders."
        case .accessDenied: return "Remit needs permission to access Reminders. Grant it in System Settings > Privacy & Security > Reminders."
        }
    }
}

/// The only place in Remit that talks to EventKit. Everything above this layer works with
/// RemitTask/RemitProject value types, never EKReminder/EKCalendar directly.
///
/// Known trap from the previous (Electron) build: Today/Upcoming counts silently diverged from
/// what Reminders.app itself showed. The date-bucketing logic below (`isDueToday`, `isOverdue`)
/// is meant to be the single source of truth other views filter against -- see ROADMAP.md
/// "Known traps".
@MainActor
final class RemindersService: ObservableObject {
    @Published private(set) var projects: [RemitProject] = []
    @Published private(set) var tasks: [RemitTask] = []
    @Published private(set) var authorizationGranted = false
    @Published var lastError: String?
    /// Tasks mid-completion: struck through and fading, but not yet written to EventKit. Views read
    /// this to animate the row out before it disappears (ROADMAP.md #4 -- "no animation... at least
    /// a completion sound and a little animation").
    @Published private(set) var completingIDs: Set<String> = []
    /// The inverse of the last reversible change, replayed by ⌘Z. Only one step deep, matching the
    /// Glaze build's `undoRef` -- enough to take back a mis-keyed `t` or `1`, which is what the
    /// shortcut is actually for.
    @Published private(set) var undoDescription: String?
    private var undoAction: (() throws -> Void)?

    func recordUndo(_ description: String, _ action: @escaping () throws -> Void) {
        undoDescription = description
        undoAction = action
    }

    func performUndo() {
        guard let undoAction else { return }
        self.undoAction = nil
        undoDescription = nil
        do {
            try undoAction()
            Task { await refreshAll() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    init() {
        authorizationGranted = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    var defaultProjectID: String? {
        store.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToReminders()
            authorizationGranted = granted
            if granted {
                await refreshAll()
            } else {
                lastError = RemindersServiceError.accessDenied.localizedDescription
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshAll() async {
        guard authorizationGranted else { return }
        let calendars = store.calendars(for: .reminder)
        projects = calendars.map { RemitProject(from: $0) }

        let fetched = await fetchReminders(in: calendars)
        tasks = fetched.map { RemitTask(from: $0) }
    }

    private func fetchReminders(in calendars: [EKCalendar]) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            let predicate = store.predicateForReminders(in: calendars)
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    @discardableResult
    func createTask(
        title: String,
        projectID: String,
        dueDate: Date? = nil,
        dueTime: DateComponents? = nil,
        priority: Priority = .p4,
        notes: String? = nil,
        recurrence: QuickAddRecurrence? = nil
    ) throws -> RemitTask {
        guard let calendar = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == projectID }) else {
            throw RemindersServiceError.projectNotFound
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        reminder.notes = notes
        reminder.priority = priority.rawValue
        if let dueDate {
            reminder.dueDateComponents = Self.dueComponents(day: dueDate, time: dueTime)
        }
        if let recurrence {
            reminder.addRecurrenceRule(Self.recurrenceRule(from: recurrence))
        }
        try store.save(reminder, commit: true)
        return RemitTask(from: reminder)
    }

    /// A reminder with `hour`/`minute` present shows a time in Reminders.app; one without shows as
    /// all-day. Keeping the time optional is what lets "due Tuesday" and "due Tuesday at 5pm" stay
    /// distinguishable after a round-trip through EventKit.
    private static func dueComponents(day: Date, time: DateComponents?) -> DateComponents {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        if let time {
            components.hour = time.hour
            components.minute = time.minute
        }
        return components
    }

    private static func recurrenceRule(from recurrence: QuickAddRecurrence) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch recurrence.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        let days = recurrence.daysOfWeek?.compactMap { index -> EKRecurrenceDayOfWeek? in
            guard let weekday = EKWeekday(rawValue: index) else { return nil }
            return EKRecurrenceDayOfWeek(weekday)
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: max(1, recurrence.interval),
            daysOfTheWeek: days,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: nil
        )
    }

    /// Completion with the sound and the brief fade, then the write. Re-opening a completed task
    /// is immediate -- only the completing direction is worth animating.
    func completeAnimated(_ task: RemitTask) {
        guard !task.isCompleted else {
            try? toggleComplete(task)
            Task { await refreshAll() }
            return
        }
        guard !completingIDs.contains(task.id) else { return }

        completingIDs.insert(task.id)
        if UserDefaults.standard.object(forKey: "general.completionSound") as? Bool ?? true {
            NSSound(named: "Glass")?.play()
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            do {
                try toggleComplete(task)
            } catch {
                lastError = error.localizedDescription
            }
            completingIDs.remove(task.id)
            await refreshAll()
        }
    }

    func toggleComplete(_ task: RemitTask) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        reminder.isCompleted.toggle()
        reminder.completionDate = reminder.isCompleted ? Date() : nil
        try store.save(reminder, commit: true)
    }

    func setPriority(_ priority: Priority, for task: RemitTask) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        reminder.priority = priority.rawValue
        try store.save(reminder, commit: true)
    }

    func setTitle(_ title: String, for task: RemitTask) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        reminder.title = title
        try store.save(reminder, commit: true)
    }

    func setNotes(_ notes: String?, for task: RemitTask) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        reminder.notes = notes
        try store.save(reminder, commit: true)
    }

    /// Moves a reminder to another list. EventKit reassigns the calendar in place, so the
    /// identifier survives and Remit-layer metadata keyed to it stays attached.
    func moveTask(_ task: RemitTask, toProject projectID: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        guard let calendar = store.calendars(for: .reminder)
            .first(where: { $0.calendarIdentifier == projectID }) else {
            throw RemindersServiceError.projectNotFound
        }
        reminder.calendar = calendar
        try store.save(reminder, commit: true)
    }

    /// Sets the due date, with `allDay` deciding whether a time component is written at all --
    /// that flag is the only thing distinguishing "due Tuesday" from "due Tuesday at 09:00" once
    /// the value round-trips through EventKit.
    func setDueDate(_ date: Date?, allDay: Bool, for task: RemitTask) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        if let date {
            let fields: Set<Calendar.Component> = allDay
                ? [.year, .month, .day]
                : [.year, .month, .day, .hour, .minute]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: date)
        } else {
            reminder.dueDateComponents = nil
        }
        try store.save(reminder, commit: true)
    }

    /// Replaces every recurrence rule, or clears them when passed nil.
    func setRecurrence(_ recurrence: QuickAddRecurrence?, for task: RemitTask) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        for rule in reminder.recurrenceRules ?? [] {
            reminder.removeRecurrenceRule(rule)
        }
        if let recurrence {
            reminder.addRecurrenceRule(Self.recurrenceRule(from: recurrence))
        }
        try store.save(reminder, commit: true)
    }

    func setLocation(_ title: String?, for task: RemitTask) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        // EKReminder has a plain `location` string; `structuredLocation` is EKEvent-only.
        reminder.location = (title?.isEmpty == false) ? title : nil
        try store.save(reminder, commit: true)
    }

    /// The task's current repeat, mapped back into the same shape quick add produces.
    func recurrence(for task: RemitTask) -> QuickAddRecurrence? {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder,
              let rule = reminder.recurrenceRules?.first else { return nil }
        let frequency: QuickAddRecurrence.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: frequency = .weekly
        }
        return QuickAddRecurrence(
            frequency: frequency,
            interval: rule.interval,
            daysOfWeek: rule.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue }
        )
    }

    func location(for task: RemitTask) -> String? {
        (store.calendarItem(withIdentifier: task.id) as? EKReminder)?.location
    }

    func setDueDate(_ date: Date?, for task: RemitTask) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        if let date {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: date
            )
        } else {
            reminder.dueDateComponents = nil
        }
        try store.save(reminder, commit: true)
    }

    /// Removes the Reminders list itself, and every reminder in it -- this is not a Remit-only
    /// hide (ROADMAP.md #34 asked for exactly that). Callers must confirm first; there is no undo,
    /// and the deletion syncs to iCloud like any other Reminders change.
    func deleteProject(_ projectID: String) throws {
        guard let calendar = store.calendars(for: .reminder)
            .first(where: { $0.calendarIdentifier == projectID }) else {
            throw RemindersServiceError.projectNotFound
        }
        try store.removeCalendar(calendar, commit: true)
    }

    func delete(_ task: RemitTask) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        try store.remove(reminder, commit: true)
    }
}

// MARK: - Date bucketing (single source of truth -- see class doc comment)

/// The dates the `T` / `U` / `W` / `N` scheduling shortcuts and the quick-add default resolve to.
/// Defined here, next to `isDueToday`/`isOverdue`, so every "what day does this mean" answer in
/// the app comes from one file -- see the class doc comment and ROADMAP.md "Known traps".
enum ScheduleTarget {
    case today
    case tomorrow
    /// The coming Saturday. Today counts when it's already the weekend, matching Todoist.
    case weekend
    case nextWeek
    case none

    var date: Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch self {
        case .today:
            return today
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: today)
        case .weekend:
            let weekday = calendar.component(.weekday, from: today)
            let daysUntilSaturday = (7 - weekday + 7) % 7
            return calendar.date(byAdding: .day, value: daysUntilSaturday, to: today)
        case .nextWeek:
            return calendar.date(byAdding: .day, value: 7, to: today)
        case .none:
            return nil
        }
    }
}

extension RemitTask {
    var isOverdue: Bool {
        guard let dueDate, !isCompleted else { return false }
        return dueDate < Calendar.current.startOfDay(for: Date())
    }

    var isDueToday: Bool {
        guard let dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }
}

// MARK: - EventKit <-> Remit model bridging

private extension RemitProject {
    init(from calendar: EKCalendar) {
        id = calendar.calendarIdentifier
        title = calendar.title
        colorHex = calendar.cgColor.map(RemitProject.hexString(from:)) ?? "#808080"
        emoji = nil
        isFavorite = false
        sortOrder = 0
        parentID = nil
    }

    static func hexString(from cgColor: CGColor) -> String {
        guard let components = cgColor.components, components.count >= 3 else { return "#808080" }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private extension RemitTask {
    init(from reminder: EKReminder) {
        id = reminder.calendarItemIdentifier
        title = reminder.title ?? "Untitled"
        notes = reminder.notes
        isCompleted = reminder.isCompleted
        if let comps = reminder.dueDateComponents, let date = Calendar.current.date(from: comps) {
            dueDate = date
            hasDueTime = comps.hour != nil
        } else {
            dueDate = nil
            hasDueTime = false
        }
        priority = Priority(ekPriority: reminder.priority)
        projectID = reminder.calendar?.calendarIdentifier ?? ""
        labels = []
        sectionID = nil
        sortOrder = 0
        url = reminder.url
        creationDate = reminder.creationDate
    }
}
