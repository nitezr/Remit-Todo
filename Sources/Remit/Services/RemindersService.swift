import AppKit
import EventKit
import Foundation
import ReminderKitBridge
import RemindersNative

enum RemindersServiceError: LocalizedError {
    case projectNotFound
    case taskNotFound
    case accessDenied
    case noReminderAccount

    var errorDescription: String? {
        switch self {
        case .projectNotFound: return "That project could not be found in Reminders."
        case .taskNotFound: return "That task could not be found in Reminders."
        case .accessDenied: return "Remit needs permission to access Reminders. Grant it in System Settings > Privacy & Security > Reminders."
        case .noReminderAccount: return "There is no Reminders account on this Mac to add a list to."
        }
    }
}

/// Whether Reminders' own tags, sections and groups could be read.
enum NativeMetadataStatus: Equatable {
    case unknown
    case available
    /// macOS is withholding Reminders' store. Reading it needs Full Disk Access, which has no
    /// permission prompt -- the user has to add Remit in System Settings themselves.
    case needsFullDiskAccess
    case unavailable(String)

    init(_ error: RemindersDatabaseError) {
        switch error {
        case .fullDiskAccessRequired: self = .needsFullDiskAccess
        case .storeNotFound: self = .unavailable("No Apple Reminders store was found on this Mac.")
        case .unreadable(let detail): self = .unavailable("Apple Reminders' store could not be read: \(detail)")
        }
    }

    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
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
    @Published var lastError: String? {
        // Demo data isn't in Reminders, so every save to it fails. Those failures say nothing
        // useful to someone trying the app, and would land in screenshots.
        didSet { if isDemo, lastError != nil { lastError = nil } }
    }
    /// Every tag in use in Reminders.
    @Published private(set) var tags: [ReminderTag] = []
    /// Project id -> its Reminders sections, in order.
    @Published private(set) var sectionsByProject: [String: [TaskSection]] = [:]
    @Published private(set) var groups: [ListGroup] = []
    @Published private(set) var nativeStatus: NativeMetadataStatus = .unknown
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
    private var activationObserver: NSObjectProtocol?
    private var storeWatcher: StoreWatcher?
    /// Set only by `init(demo:)`.
    private var isDemo = false
    private var demoDefaultProjectID: String?

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
        // Coming back to Remit re-reads, so an edit made in Reminders.app while Remit was in the
        // background is there on return even if nothing else noticed it.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
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
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Remit on made-up data (`--demo`, see DemoMode). Nothing is read from or written to
    /// EventKit or Reminders' store: `refreshAll` does nothing, and tag and section changes stay on
    /// screen without being saved anywhere.
    init(demo data: DemoData) {
        isDemo = true
        demoDefaultProjectID = DemoData.inboxID
        authorizationGranted = true
        nativeStatus = .available
        projects = data.projects
        tasks = data.tasks
        tags = data.tags
        sectionsByProject = data.sections
        groups = data.groups
    }

    var defaultProjectID: String? {
        if isDemo { return demoDefaultProjectID }
        return store.defaultCalendarForNewReminders()?.calendarIdentifier
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
        guard authorizationGranted, !isDemo else { return }
        let calendars = store.calendars(for: .reminder)
        var fetchedProjects = calendars.map { RemitProject(from: $0) }
        var fetchedTasks = await fetchReminders(in: calendars).map { RemitTask(from: $0) }

        // Off the main actor: this reads the whole of Reminders' store.
        let native = await Task.detached(priority: .userInitiated) { RemindersDatabase.load() }.value
        applyNative(native, projects: &fetchedProjects, tasks: &fetchedTasks)

        // Assigned only on change. The store watcher refreshes on every write Reminders makes, and
        // republishing identical arrays would re-render every view each time.
        if projects != fetchedProjects { projects = fetchedProjects }
        if tasks != fetchedTasks { tasks = fetchedTasks }
    }

    /// Joins Reminders' own tags, sections and groups onto what EventKit returned. EventKit's
    /// identifiers are ReminderKit's identifiers, so this is a lookup rather than a mapping table.
    private func applyNative(
        _ result: Result<RemindersSnapshot, RemindersDatabaseError>,
        projects: inout [RemitProject],
        tasks: inout [RemitTask]
    ) {
        let snapshot: RemindersSnapshot
        switch result {
        case .success(let value):
            snapshot = value
            RemitLog.debug(
                "native read: \(value.tagNames.count) tags on \(value.tagsByReminder.count) reminders, "
                    + "\(value.sectionsByList.values.reduce(0) { $0 + $1.count }) sections holding "
                    + "\(value.sectionByReminder.count) reminders, \(value.groups.count) groups"
            )
            if nativeStatus != .available { nativeStatus = .available }
            startWatchingStore()
        case .failure(let error):
            RemitLog.debug("native read failed: \(error)")
            let status = NativeMetadataStatus(error)
            if nativeStatus != status { nativeStatus = status }
            if !tags.isEmpty { tags = [] }
            if !sectionsByProject.isEmpty { sectionsByProject = [:] }
            if !groups.isEmpty { groups = [] }
            return
        }

        let projectIDs = Dictionary(
            projects.map { ($0.id.uppercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        var sections: [String: [TaskSection]] = [:]
        for (listID, listSections) in snapshot.sectionsByList {
            guard let projectID = projectIDs[listID] else { continue }
            sections[projectID] = listSections.map {
                TaskSection(id: $0.id, projectID: projectID, name: $0.name, sortOrder: $0.order)
            }
        }

        for index in projects.indices {
            projects[index].groupID = snapshot.groupByList[projects[index].id.uppercased()]
        }
        for index in tasks.indices {
            let key = tasks[index].id.uppercased()
            tasks[index].labels = snapshot.tagsByReminder[key] ?? []
            // A membership outlives a move to another list; only a section of the task's own list
            // counts, or a moved task would render under a heading its new list doesn't have.
            if let sectionID = snapshot.sectionByReminder[key],
               sections[tasks[index].projectID]?.contains(where: { $0.id == sectionID }) == true {
                tasks[index].sectionID = sectionID
            }
        }

        let newTags = snapshot.tagNames.map(ReminderTag.init(name:))
        let newGroups = snapshot.groups.map { group in
            ListGroup(id: group.id, name: group.name, projectIDs: group.listIDs.compactMap { projectIDs[$0] })
        }
        if tags != newTags { tags = newTags }
        if sectionsByProject != sections { sectionsByProject = sections }
        if groups != newGroups { groups = newGroups }
    }

    private func startWatchingStore() {
        guard storeWatcher == nil else { return }
        storeWatcher = StoreWatcher(directory: RemindersDatabase.storeDirectory) { [weak self] in
            Task { @MainActor in
                await self?.refreshAll()
            }
        }
    }

    private func fetchReminders(in calendars: [EKCalendar]) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            let predicate = store.predicateForReminders(in: calendars)
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    // MARK: - Welcome tour

    /// The tour's practice list, if it is already in Reminders.
    var tourProject: RemitProject? {
        projects.first { $0.title == TourContent.listName }
    }

    /// Adds the welcome tour's practice list: a Reminders list with the tour's tasks, and -- when
    /// Reminders' store is readable -- their sections and tags. Adding it twice returns the list
    /// already there rather than a duplicate.
    ///
    /// Tasks go in through EventKit first, so a Mac without Full Disk Access still gets a usable
    /// list. Sections and tags follow in one ReminderKit pass, in order: each section create sends
    /// the list's whole section order, so they cannot run side by side.
    @discardableResult
    func createTourList() async throws -> String {
        if let existing = tourProject { return existing.id }

        let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { !$0.calendars(for: .reminder).isEmpty }
        guard let source else { throw RemindersServiceError.noReminderAccount }

        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = TourContent.listName
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        let listID = calendar.calendarIdentifier

        var placed: [(section: String, taskID: String, tags: [String])] = []
        for item in TourContent.tasks {
            let task = try createTask(
                title: item.title,
                projectID: listID,
                dueDate: item.dueToday ? ScheduleTarget.today.date : nil,
                priority: item.priority,
                notes: item.notes
            )
            placed.append((item.section, task.id, item.tags))
        }
        await refreshAll()

        guard nativeStatus == .available else { return listID }
        let sectionNames = TourContent.sections
        let plan = placed
        do {
            try await Task.detached(priority: .userInitiated) {
                var ordering: [String] = []
                var sectionIDs: [String: String] = [:]
                for name in sectionNames {
                    let id = try RKBridge.createSectionNamed(name, inList: listID, existingSectionIDs: ordering)
                    ordering.append(id)
                    sectionIDs[name] = id
                }
                for item in plan {
                    if let sectionID = sectionIDs[item.section] {
                        try RKBridge.moveReminder(item.taskID, toSection: sectionID, leavingSection: nil)
                    }
                    if !item.tags.isEmpty {
                        try RKBridge.setTags(item.tags, forReminder: item.taskID)
                    }
                }
            }.value
        } catch {
            // The list and its tasks already exist; a failed section or tag step shouldn't read as
            // the whole tour failing, so it surfaces as a banner instead.
            RemitLog.debug("tour sections/tags failed: \(error.localizedDescription)")
            lastError = "The tour list was added, but its sections or tags weren't: \(error.localizedDescription)"
        }
        await refreshAll()
        return listID
    }

    // MARK: - Tags, sections and groups

    func sections(forProject projectID: String) -> [TaskSection] {
        sectionsByProject[projectID] ?? []
    }

    /// The freshest copy of a task. Views hold RemitTask values, which go stale the moment a write
    /// lands; anything computing a *new* tag set or section from the old one must start from here.
    func current(_ task: RemitTask) -> RemitTask {
        tasks.first { $0.id == task.id } ?? task
    }

    /// Replaces the task's tags. Creates any tag Reminders doesn't have yet -- in Reminders a tag
    /// exists because a reminder carries it, so there is nothing to create first.
    func setTags(_ names: [String], for task: RemitTask) {
        guard requireNativeRead(to: "change tags") else { return }
        let cleaned = Self.uniqueTagNames(names)
        let id = task.id
        guard current(task).labels != cleaned else { return }
        patchTask(id) { $0.labels = cleaned }
        nativeWrite { try RKBridge.setTags(cleaned, forReminder: id) }
    }

    func setSection(_ sectionID: String?, for task: RemitTask) {
        guard requireNativeRead(to: "move tasks between sections") else { return }
        let previous = current(task).sectionID
        guard previous != sectionID else { return }
        let id = task.id
        patchTask(id) { $0.sectionID = sectionID }
        nativeWrite {
            try RKBridge.moveReminder(id, toSection: sectionID, leavingSection: previous)
        }
    }

    func createSection(named name: String, inProject projectID: String) {
        createSections(named: [name], inProject: projectID)
    }

    /// Creates sections one after another in a single write. Each create sends the list's whole
    /// section order, so two creates racing would each leave the other's section out of it.
    func createSections(named names: [String], inProject projectID: String) {
        guard requireNativeRead(to: "add sections") else { return }
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        let existing = sections(forProject: projectID).map(\.id)
        nativeWrite {
            var ordering = existing
            for name in cleaned {
                let created = try RKBridge.createSectionNamed(name, inList: projectID, existingSectionIDs: ordering)
                ordering.append(created)
            }
        }
    }

    func renameSection(_ section: TaskSection, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != section.name else { return }
        let id = section.id
        nativeWrite { try RKBridge.renameSection(id, to: trimmed) }
    }

    /// Deletes the section in Reminders. Its tasks stay in the list, unsectioned.
    func deleteSection(_ section: TaskSection) {
        let id = section.id
        nativeWrite { try RKBridge.deleteSection(id) }
    }

    func setGroup(_ groupID: String?, forProject projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }),
              projects[index].groupID != groupID else { return }
        projects[index].groupID = groupID
        nativeWrite { try RKBridge.setGroup(groupID, forList: projectID) }
    }

    /// Renames a tag everywhere it is used, completed tasks included, which is what renaming a tag
    /// means in Reminders. Renaming onto an existing tag merges the two.
    func renameTag(_ oldName: String, to newName: String) {
        guard requireNativeRead(to: "rename tags") else { return }
        guard let replacement = Self.uniqueTagNames([newName]).first, replacement != oldName else { return }
        rewriteTags { names in
            guard names.contains(oldName) else { return nil }
            return names.map { $0 == oldName ? replacement : $0 }
        }
    }

    /// Takes a tag off every task carrying it. The tasks themselves are untouched.
    func removeTag(_ name: String) {
        guard requireNativeRead(to: "remove tags") else { return }
        rewriteTags { names in
            guard names.contains(name) else { return nil }
            return names.filter { $0 != name }
        }
    }

    private func rewriteTags(_ transform: ([String]) -> [String]?) {
        let changes = tasks.compactMap { task -> (String, [String])? in
            guard let updated = transform(task.labels) else { return nil }
            return (task.id, Self.uniqueTagNames(updated))
        }
        guard !changes.isEmpty else { return }
        for (id, names) in changes {
            patchTask(id) { $0.labels = names }
        }
        nativeWrite {
            for (id, names) in changes {
                try RKBridge.setTags(names, forReminder: id)
            }
        }
    }

    /// Tag and section writes replace whole sets computed from what was last read. Without a read
    /// that starting point is empty, and writing from it would strip every existing tag or drop
    /// every section from a list's order -- so these refuse rather than guess.
    private func requireNativeRead(to action: String) -> Bool {
        switch nativeStatus {
        case .available:
            return true
        case .needsFullDiskAccess:
            lastError = "Remit can't \(action) until it has Full Disk Access to read your Reminders tags and sections."
        case .unavailable(let message):
            lastError = message
        case .unknown:
            lastError = "Remit hasn't finished reading your Reminders tags and sections yet."
        }
        return false
    }

    /// Runs a ReminderKit write off the main thread -- each is an XPC round trip to Reminders'
    /// daemon -- then re-reads. The re-read settles the optimistic value views already show: it
    /// sticks if the write landed, and reverts to what Reminders really holds if it didn't.
    private func nativeWrite(_ work: @escaping @Sendable () throws -> Void) {
        guard !isDemo else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try work() }.value
            } catch {
                RemitLog.debug("native write failed: \(error.localizedDescription)")
                lastError = error.localizedDescription
            }
            await refreshAll()
        }
    }

    private func patchTask(_ id: String, _ change: (inout RemitTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
    }

    /// Trimmed, without a typed leading `#`, and de-duplicated case-insensitively -- Reminders
    /// treats `#Work` and `#work` as one tag.
    static func uniqueTagNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in names {
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while name.hasPrefix("#") { name.removeFirst() }
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            result.append(name)
        }
        return result
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
        groupID = nil
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
        isRecurring = reminder.hasRecurrenceRules
        url = reminder.url
        creationDate = reminder.creationDate
    }
}
