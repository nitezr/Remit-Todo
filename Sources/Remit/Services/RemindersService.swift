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
        priority: Priority = .p4,
        notes: String? = nil
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
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }
        try store.save(reminder, commit: true)
        return RemitTask(from: reminder)
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

    func delete(_ task: RemitTask) throws {
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else {
            throw RemindersServiceError.taskNotFound
        }
        try store.remove(reminder, commit: true)
    }
}

// MARK: - Date bucketing (single source of truth -- see class doc comment)

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
