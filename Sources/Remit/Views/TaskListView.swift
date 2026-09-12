import AppKit
import SwiftUI

/// Filters `remindersService.tasks` for the current sidebar selection and renders it grouped into
/// sections, each ending with its own inline "Add task" row.
///
/// The Electron build's Today/Upcoming counts drifted from Reminders.app's own counts twice
/// (ROADMAP.md "Known traps") and its arrow-key navigation skipped items twice. Both are handled
/// in one place on purpose: `visibleTasks` is the only place tasks are selected for this view, and
/// `moveSelection` walks `orderedTasks` -- the flattened rendered order -- rather than a
/// separately-maintained index, so a selection can never point at a row the filter no longer shows.
struct TaskListView: View {
    let selection: SidebarSelection
    /// Lets the ⌘K palette move the sidebar selection, which this view doesn't own.
    var onNavigate: ((SidebarSelection) -> Void)?

    @EnvironmentObject private var remindersService: RemindersService
    @EnvironmentObject private var metadataStore: MetadataStore
    @State private var quickAddText = ""
    @State private var activeAddSection: String?
    @State private var newSectionName = ""
    @State private var addingSection = false
    @State private var renamingSection: TaskSection?

    @State private var labelSheetTask: RemitTask?
    @State private var peekTask: RemitTask?
    @State private var selectedTaskID: String?
    @FocusState private var focus: RemitFocusTarget?
    @StateObject private var keyMonitor = KeyMonitor()
    @EnvironmentObject private var displayPrefs: DisplayPrefsStore
    @EnvironmentObject private var shortcuts: ShortcutsStore
    @EnvironmentObject private var uiState: UIState

    var body: some View {
        VStack(spacing: 0) {
            switch layout {
            case .list:
                listLayout
            case .board:
                BoardView(
                    sections: sections,
                    showsProject: showsProjectColumn,
                    selectedTaskID: $selectedTaskID,
                    onAddSection: boardSectionAdder,
                    onDrop: { task, section in move(task, to: section) },
                    onAddTask: { section in
                        activeAddSection = section.id
                        focus = .quickAdd
                    },
                    // Only the date-driven views get the big header; a project board already has
                    // its name in the window title, and a month line under it would be meaningless.
                    boardTitle: selection == .upcoming ? "Upcoming" : nil,
                    onRescheduleAll: rescheduleAll,
                    taskMenu: { task in taskMenu(task) }
                )
            case .calendar:
                CalendarView(
                    tasks: visibleTasks,
                    selectedTaskID: $selectedTaskID,
                    range: binding(\.calendarRange)
                ) { task, date in
                    perform { try remindersService.setDueDate(date, for: task) }
                }
            }

            if let error = remindersService.lastError {
                ErrorBanner(message: error) { remindersService.lastError = nil }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DisplayMenu(
                    layout: binding(\.layout),
                    groupBy: binding(\.groupBy),
                    sorting: binding(\.sorting),
                    showsCompleted: binding(\.showsCompleted),
                    deadline: binding(\.deadline),
                    priorityFilter: binding(\.priorityFilter),
                    labelFilter: binding(\.labelFilter),
                    labels: remindersService.tags,
                    onReset: resetDisplay,
                    onSaveFilter: saveCurrentAsFilter
                )
            }
        }
        .task(id: selection) {
            await remindersService.refreshAll()
        }
        // Both of these were set but never presented: `i` / Return / double-click filled peekTask
        // and `l` filled labelSheetTask, and nothing ever showed either one. That is exactly the
        // failure ROADMAP.md records three times over (#76-#78) -- a feature that exists in code,
        // is wired to its shortcut, and still does nothing on screen.
        .sheet(item: $peekTask) { task in
            TaskDetailPeek(
                task: task,
                siblings: orderedTasks,
                onNavigate: { peekTask = $0 },
                onDismiss: { peekTask = nil }
            )
        }
        .sheet(item: $labelSheetTask) { task in
            TaskLabelsSheet(task: task) { labelSheetTask = nil }
        }
        .onAppear {
            RemitLog.debug("install monitor for \(selection.displayKey)")
            keyMonitor.install(handleEvent)
            openDemoState()
        }
        .onDisappear { keyMonitor.remove() }
    }

    /// `--demo-peek` and `--demo-quick-add`: the states the README screenshots show, opened without
    /// anyone clicking. Does nothing outside demo mode.
    private func openDemoState() {
        if let title = DemoMode.peekTitle, peekTask == nil {
            peekTask = remindersService.tasks.first { $0.title == title }
        }
        if let text = DemoMode.quickAddText {
            activeAddSection = sections.first { !$0.isOverdue }?.id
            quickAddText = text
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                focus = .quickAdd
            }
        }
    }

    /// Only a project view has sections, and only when the Display menu isn't overriding the
    /// grouping -- adding a section while grouped by priority would create something invisible.
    private var boardSectionAdder: ((String) -> Void)? {
        guard case .project(let projectID) = selection, groupBy == .default else { return nil }
        return { name in remindersService.createSection(named: name, inProject: projectID) }
    }

    /// This view's own settings. Keyed by `selection`, so each project, label, and fixed view
    /// keeps its own layout, grouping, sorting, and filters.
    private var prefs: DisplayPreferences {
        displayPrefs.preferences(for: selection.displayKey)
    }

    private var layout: TaskLayout { prefs.layout }
    private var sorting: TaskSorting { prefs.sorting }
    private var groupBy: TaskGroupBy { prefs.groupBy }
    private var deadline: DeadlineFilter { prefs.deadline }
    private var showsCompleted: Bool { prefs.showsCompleted }
    private var priorityFilter: String { prefs.priorityFilter }
    private var labelFilter: String { prefs.labelFilter }

    private func binding<V>(_ keyPath: WritableKeyPath<DisplayPreferences, V>) -> Binding<V> {
        Binding(
            get: { prefs[keyPath: keyPath] },
            set: { newValue in
                var updated = prefs
                updated[keyPath: keyPath] = newValue
                displayPrefs.set(updated, for: selection.displayKey)
            }
        )
    }

    /// Turns the popover's current criteria into a named sidebar filter. Reminders has no filter
    /// concept, so these are entirely Remit's (#27).
    private func saveCurrentAsFilter(_ name: String) {
        var projectID: String?
        if case .project(let id) = selection { projectID = id }
        metadataStore.addFilter(
            SavedFilter(
                id: UUID().uuidString,
                name: name,
                deadline: deadline,
                priority: priorityFilter,
                labelID: labelFilter,
                projectID: projectID
            )
        )
    }

    private func resetDisplay() {
        displayPrefs.reset(selection.displayKey)
    }

    /// Dropping a card on a board column means "belong to this group": for a project that's a
    /// section change, for a date-based view it's a reschedule.
    private func move(_ task: RemitTask, to section: TaskGrouping.Section) {
        if section.isSectionBucket {
            remindersService.setSection(section.sectionID, for: task)
        } else if let date = section.date {
            perform { try remindersService.setDueDate(date, for: task) }
        }
    }

    /// A drag in the List layout ends here. Each task joins the group it was dropped on, unless it
    /// is already in it -- re-dating a task onto its own day would throw away its time of day.
    private func dropTasks(_ ids: [String], into section: TaskGrouping.Section) {
        for id in ids {
            guard let task = remindersService.tasks.first(where: { $0.id == id }) else { continue }
            if section.isSectionBucket, task.sectionID == section.sectionID { continue }
            if let date = section.date, let due = task.dueDate,
               Calendar.current.isDate(due, inSameDayAs: date) { continue }
            move(task, to: section)
        }
    }

    /// Reordering by drag exists only under Manual sort; nil turns it off everywhere else.
    private func moveHandler(for section: TaskGrouping.Section) -> ((IndexSet, Int) -> Void)? {
        guard sorting == .manual else { return nil }
        return { source, destination in
            moveTasks(in: section, from: source, to: destination)
        }
    }

    private var listLayout: some View {
        // No `selection:` binding on purpose. macOS draws its own full-bleed grey highlight for a
        // selected row and offers no way to restyle it, so it showed through around the row's own
        // card as a grey band. Selection is ours: keyboard movement already went through
        // `moveSelection`, and a single tap covers the mouse. ScrollViewReader then keeps `j`/`k`
        // from walking the selection off screen, which List's own selection used to handle.
        ScrollViewReader { proxy in
            List {
                ForEach(sections) { section in
                    if let gap = section.gapLabel {
                        Text(gap)
                            .font(Theme.font(11))
                            .foregroundStyle(.tertiary)
                            .listRowSeparator(.hidden)
                    }

                    SwiftUI.Section {
                        ForEach(section.tasks) { task in
                            TaskRowView(
                                task: task,
                                showsProject: showsProjectColumn,
                                isSelected: selectedTaskID == task.id
                            )
                                .id(task.id)
                                // The row draws its own card and its own padding, so List's
                                // separator and insets would double up on both.
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                                .listRowBackground(Color.clear)
                                .contextMenu { taskMenu(task) }
                                // Double before single: the reverse order lets the single tap win
                                // the gesture and the peek never opens.
                                .onTapGesture(count: 2) { peekTask = task }
                                .onTapGesture { selectedTaskID = task.id }
                                .modifier(TaskDrag(id: task.id, enabled: sorting != .manual))
                        }
                        // Two different drags. Under Manual sort a drag reorders within the group;
                        // under any computed sort a reorder would snap straight back, so a drag
                        // moves the task to another group instead -- a section in a project, a day
                        // in Upcoming -- the same as dropping a card on a board column.
                        .onMove(perform: moveHandler(for: section))
                        .dropDestination(for: String.self) { ids, _ in
                            dropTasks(ids, into: section)
                        }

                        // Overdue never takes new tasks -- adding "to Overdue" has no meaning.
                        if !section.isOverdue {
                            addRow(for: section)
                                .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 12))
                        }
                    } header: {
                        Text(section.title)
                            .font(Theme.sectionHeader)
                            .foregroundStyle(Theme.primaryText)
                            // Leading 18 lines the header up with the row title above it: 6pt of
                            // card margin plus the card's own 12pt of padding.
                            .listRowInsets(EdgeInsets(top: 14, leading: 18, bottom: 4, trailing: 12))
                            .contextMenu { sectionMenu(section) }
                            // An empty group has no rows to drop between, so its header takes drops.
                            .dropDestination(for: String.self) { ids, _ in
                                dropTasks(ids, into: section)
                                return !ids.isEmpty
                            }
                    }
                }

                if case .project = selection {
                    addSectionRow
                        .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 12))
                }
            }
            .listStyle(.plain)
            // Otherwise List paints its own system white and the off-white page colour never
            // shows, which is what made every surface the same brightness.
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
            .onChange(of: selectedTaskID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Collapsed to a plain "Add task" affordance until clicked, so a long Upcoming list isn't a
    /// column of identical text fields.
    @ViewBuilder
    private func addRow(for section: TaskGrouping.Section) -> some View {
        if activeAddSection == section.id {
            QuickAddView(
                text: $quickAddText,
                isFocused: $focus,
                focusValue: .quickAdd,
                projects: remindersService.projects,
                labels: remindersService.tags,
                onSubmit: { submitQuickAdd(into: section) }
            )
            .listRowSeparator(.hidden)
        } else {
            Button {
                activeAddSection = section.id
                focus = .quickAdd
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                    Text("Add task")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
        }
    }

    /// Creates a real Reminders section, so it appears under this list in Reminders.app too.
    @ViewBuilder
    private var addSectionRow: some View {
        if addingSection {
            HStack(spacing: 8) {
                Image(systemName: "square.split.1x2")
                    .foregroundStyle(.secondary)
                TextField("Section name", text: $newSectionName)
                    .textFieldStyle(.plain)
                    .onSubmit(commitSection)
                    .onExitCommand { cancelSection() }
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        } else {
            Button {
                addingSection = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.square.dashed")
                    Text("Add section")
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func sectionMenu(_ section: TaskGrouping.Section) -> some View {
        if let sectionID = section.sectionID,
           let model = projectSections.first(where: { $0.id == sectionID }) {
            Button("Rename Section") {
                renamingSection = model
                newSectionName = model.name
                addingSection = true
            }
            // Deleting a section in Reminders returns its tasks to the unsectioned bucket; it
            // never deletes the tasks themselves.
            Button("Delete Section", role: .destructive) {
                remindersService.deleteSection(model)
            }
        }
    }

    /// Everything you can do to a task, from the task itself.
    ///
    /// A macOS context menu is a vertical list, so Todoist's horizontal date and priority strips
    /// become submenus rather than icon rows. Shortcut letters are read from ShortcutsStore rather
    /// than hardcoded, so a remapped key shows its real binding here instead of a stale one -- and
    /// they are shown as text rather than attached with `.keyboardShortcut`, which would register
    /// a second handler competing with the key monitor.
    @ViewBuilder
    private func taskMenu(_ task: RemitTask) -> some View {
        Button("Edit\(hint(.openDetail))") { peekTask = task }
        if !isProjectView, let project = project(for: task) {
            Button("Go to \(project.title)") { onNavigate?(.project(project.id)) }
        }

        Divider()

        Menu("Due Date") {
            Button("Today\(hint(.scheduleToday))") { reschedule(task, to: .today) }
            Button("Tomorrow\(hint(.scheduleTomorrow))") { reschedule(task, to: .tomorrow) }
            Button("This Weekend\(hint(.scheduleWeekend))") { reschedule(task, to: .weekend) }
            Button("Next Week\(hint(.scheduleNextWeek))") { reschedule(task, to: .nextWeek) }
            Divider()
            Button("No Date\(hint(.scheduleClear))") { reschedule(task, to: ScheduleTarget.none) }
        }

        Menu("Priority") {
            ForEach(Priority.allCases) { priority in
                Button {
                    setPriority(priority, on: task)
                } label: {
                    // The flag reads as the colour Todoist uses, and the tick marks the current
                    // one -- a priority menu that does not say which is set is half a menu.
                    Label(
                        priority.label + (task.priority == priority ? " ✓" : ""),
                        systemImage: "flag.fill"
                    )
                }
            }
        }

        Button("Tags...\(hint(.editLabels))") { labelSheetTask = task }

        Divider()

        Menu("Move to Project") {
            ForEach(remindersService.projects) { project in
                Button(project.title) {
                    guard project.id != task.projectID else { return }
                    perform { try remindersService.moveTask(task, toProject: project.id) }
                }
                .disabled(project.id == task.projectID)
            }
        }

        if case .project = selection, !projectSections.isEmpty {
            Menu("Move to Section") {
                Button("(No section)") { remindersService.setSection(nil, for: task) }
                Divider()
                ForEach(projectSections) { section in
                    Button(section.name) { remindersService.setSection(section.id, for: task) }
                }
            }
        }

        Button("Duplicate") { duplicate(task) }
        Button("Copy Title") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.title, forType: .string)
        }

        Divider()

        Button(task.isCompleted ? "Mark Incomplete" : "Complete\(hint(.completeTask))") {
            remindersService.completeAnimated(task)
        }
        Button("Delete Task", role: .destructive) {
            let previous = task
            remindersService.recordUndo("delete task") {
                _ = try remindersService.createTask(
                    title: previous.title,
                    projectID: previous.projectID,
                    dueDate: previous.dueDate,
                    priority: previous.priority,
                    notes: previous.notes
                )
            }
            perform { try remindersService.delete(task) }
        }
    }

    /// " (T)" for an action with a single-key binding, empty otherwise. Multi-key or modifier
    /// chords are left out: they read as noise in a menu item's name.
    private func hint(_ action: ShortcutAction) -> String {
        guard let binding = shortcuts.bindings(for: action).first,
              binding.modifiers == 0,
              let character = binding.character,
              character.count == 1 else { return "" }
        return "  (\(character.uppercased()))"
    }

    private var isProjectView: Bool {
        if case .project = selection { return true }
        return false
    }

    private func project(for task: RemitTask) -> RemitProject? {
        remindersService.projects.first { $0.id == task.projectID }
    }

    private func reschedule(_ task: RemitTask, to target: ScheduleTarget) {
        let previous = task.dueDate
        remindersService.recordUndo("reschedule") {
            try remindersService.setDueDate(previous, for: task)
        }
        perform { try remindersService.setDueDate(target.date, for: task) }
    }

    private func setPriority(_ priority: Priority, on task: RemitTask) {
        let previous = task.priority
        remindersService.recordUndo("priority") {
            try remindersService.setPriority(previous, for: task)
        }
        perform { try remindersService.setPriority(priority, for: task) }
    }

    /// Copies the fields EventKit stores, then the tags and section -- which EventKit can't write --
    /// through ReminderKit once the new task has an id.
    private func duplicate(_ task: RemitTask) {
        perform {
            let copy = try remindersService.createTask(
                title: task.title,
                projectID: task.projectID,
                dueDate: task.dueDate,
                priority: task.priority,
                notes: task.notes
            )
            if !task.labels.isEmpty { remindersService.setTags(task.labels, for: copy) }
            if let sectionID = task.sectionID { remindersService.setSection(sectionID, for: copy) }
        }
    }

    private func commitSection() {
        guard case .project(let projectID) = selection else { return }
        let name = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return cancelSection() }

        if let renamingSection {
            remindersService.renameSection(renamingSection, to: name)
        } else {
            remindersService.createSection(named: name, inProject: projectID)
        }
        cancelSection()
    }

    private func cancelSection() {
        addingSection = false
        renamingSection = nil
        newSectionName = ""
    }

    // MARK: - Data

    private var visibleTasks: [RemitTask] {
        let openTasks = remindersService.tasks
            .filter { showsCompleted || !$0.isCompleted }
            .filter(passesFilters)
        switch selection {
        case .inbox:
            let defaultID = remindersService.defaultProjectID
            return openTasks.filter { $0.projectID == defaultID }
        case .today:
            return openTasks.filter { $0.isDueToday || $0.isOverdue }
        case .upcoming:
            let startOfToday = Calendar.current.startOfDay(for: Date())
            return openTasks.filter { ($0.dueDate ?? .distantPast) >= startOfToday || $0.isOverdue }
        case .label(let name):
            return openTasks.filter { $0.labels.contains(name) }
        case .filter(let filterID):
            guard let filter = metadataStore.filters.first(where: { $0.id == filterID }) else { return [] }
            return openTasks.filter { filter.matches($0, labelIDs: $0.labels) }
        case .filtersAndLabels:
            return []
        case .project(let id):
            return openTasks.filter { $0.projectID == id }
        }
    }

    /// Hides tasks whose due *time* falls inside the configured sleeping window (#10, default
    /// 10PM-8AM). Only tasks with an explicit time are affected -- an all-day task has no time to
    /// judge, and hiding those would make tasks disappear for no visible reason.
    ///
    /// Midnight is treated as no time at all. Reminders records plenty of ordinary dated tasks at
    /// exactly 00:00 local with an hour component present, so `hasDueTime` is true for them and
    /// hour 0 sits inside the default window -- which hid a third of Today for a user east of UTC who
    /// had never scheduled anything overnight. The setting exists to hide a 3am alarm, not to hide
    /// every task that happens to carry a date.
    private func passesSleepingHours(_ task: RemitTask) -> Bool {
        guard UserDefaults.standard.bool(forKey: "general.hideSleepingHours"),
              task.hasDueTime, let due = task.dueDate else { return true }

        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: due)
        if components.hour == 0 && (components.minute ?? 0) == 0 { return true }

        let defaults = UserDefaults.standard
        let start = defaults.object(forKey: "general.sleepStartHour") as? Int ?? 22
        let end = defaults.object(forKey: "general.sleepEndHour") as? Int ?? 8
        let hour = calendar.component(.hour, from: due)

        // The window normally wraps midnight (22 -> 8); handle both orientations.
        let asleep = start <= end ? (hour >= start && hour < end) : (hour >= start || hour < end)
        return !asleep
    }

    /// Display-menu filters, applied on top of the view's own selection.
    private func passesFilters(_ task: RemitTask) -> Bool {
        guard passesSleepingHours(task) else { return false }
        guard deadline.matches(task) else { return false }
        if priorityFilter != "all", String(task.priority.rawValue) != priorityFilter { return false }
        if labelFilter != "all", !task.labels.contains(labelFilter) { return false }
        return true
    }

    /// Applies the chosen sort, with Manual resolved here because it needs the metadata store.
    private func applySort(_ tasks: [RemitTask]) -> [RemitTask] {
        guard sorting == .manual else { return sorting.apply(tasks) }
        return tasks.sorted { metadataStore.sortOrder(forTask: $0.id) < metadataStore.sortOrder(forTask: $1.id) }
    }

    private var sections: [TaskGrouping.Section] {
        if groupBy != .default {
            return TaskGrouping.grouped(
                applySort(visibleTasks),
                by: groupBy,
                projects: remindersService.projects,
                labelsFor: { $0.labels.map(ReminderTag.init(name:)) },
                untitled: title
            )
        }
        switch selection {
        case .today:
            return TaskGrouping.today(visibleTasks)
        case .upcoming:
            return TaskGrouping.upcoming(visibleTasks)
        case .project(let id):
            return TaskGrouping.project(
                visibleTasks,
                sections: remindersService.sections(forProject: id),
                untitled: title
            )
        case .inbox, .label, .filter, .filtersAndLabels:
            return [
                TaskGrouping.Section(
                    id: "all",
                    title: title,
                    tasks: applySort(visibleTasks)
                )
            ]
        }
    }

    private var projectSections: [TaskSection] {
        guard case .project(let id) = selection else { return [] }
        return remindersService.sections(forProject: id)
    }

    /// The rendered order, flattened. Keyboard navigation walks this so `j` crosses section
    /// boundaries the way the eye does.
    private var orderedTasks: [RemitTask] {
        sections.flatMap(\.tasks)
    }

    private var title: String {
        switch selection {
        case .inbox: return "Inbox"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .filtersAndLabels: return "Filters & Tags"
        case .label(let name):
            return "#\(name)"
        case .filter(let id):
            return metadataStore.filters.first(where: { $0.id == id })?.name ?? "Filter"
        case .project(let id):
            return remindersService.projects.first(where: { $0.id == id })?.title ?? "Project"
        }
    }

    /// Date-based views mix projects, so each row names its own. A project view doesn't.
    private var showsProjectColumn: Bool {
        switch selection {
        case .today, .upcoming, .label, .filter: return true
        case .inbox, .project, .filtersAndLabels: return false
        }
    }

    private var subtitle: String {
        let count = orderedTasks.count
        let base = count == 1 ? "1 task" : "\(count) tasks"
        // A filter removing rows must say so. The sidebar badge deliberately counts the *unfiltered*
        // set so it still agrees with Reminders.app (ROADMAP.md "Known traps" #2, #79) -- which
        // means without this the two numbers silently contradict each other, and tasks appear to
        // have gone missing. Sleeping-hours in particular hides timed tasks with no other cue.
        let hidden = unfilteredCount - count
        guard hidden > 0 else { return base }
        return "\(base) · \(hidden) hidden by filters"
    }

    /// The same date bucketing as `visibleTasks`, without the Display-menu and sleeping-hours
    /// filters, so "hidden" above is measured against what this view would otherwise show.
    private var unfilteredCount: Int {
        let open = remindersService.tasks.filter { showsCompleted || !$0.isCompleted }
        switch selection {
        case .today:
            return open.filter { $0.isDueToday || $0.isOverdue }.count
        case .upcoming:
            let startOfToday = Calendar.current.startOfDay(for: Date())
            return open.filter { ($0.dueDate ?? .distantPast) >= startOfToday || $0.isOverdue }.count
        case .inbox:
            let defaultID = remindersService.defaultProjectID
            return open.filter { $0.projectID == defaultID }.count
        case .project(let id):
            return open.filter { $0.projectID == id }.count
        case .label, .filter, .filtersAndLabels:
            return orderedTasks.count
        }
    }

    // MARK: - Quick add

    /// The due date a task gets when the typed text names no date of its own -- the section it was
    /// added under. Without this, adding from Today created an undated reminder that immediately
    /// failed this view's own filter and appeared to vanish.
    private func defaultDueDate(for section: TaskGrouping.Section) -> Date? {
        if let date = section.date { return date }
        switch selection {
        case .today, .upcoming: return ScheduleTarget.today.date
        case .inbox, .project, .label, .filter, .filtersAndLabels: return nil
        }
    }

    private func submitQuickAdd(into section: TaskGrouping.Section) {
        let parsed = QuickAddParser.parse(
            quickAddText,
            projects: remindersService.projects,
            labels: remindersService.tags.map(\.name)
        )
        let trimmed = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let targetProjectID = resolveProjectID(parsed.projectID) else {
            remindersService.lastError = "No project available to add this task to."
            return
        }

        do {
            let task = try remindersService.createTask(
                title: trimmed,
                projectID: targetProjectID,
                dueDate: parsed.dueDate ?? defaultDueDate(for: section),
                dueTime: parsed.dueTime,
                priority: parsed.priority ?? .p4,
                recurrence: parsed.recurrence
            )
            // An `@tag` Reminders doesn't have yet still lands: a Reminders tag comes into being
            // the moment a reminder carries it, so known and new names are written the same way.
            let tagNames = parsed.labelNames + parsed.newLabelNames
            if !tagNames.isEmpty { remindersService.setTags(tagNames, for: task) }
            if section.isSectionBucket, let sectionID = section.sectionID {
                remindersService.setSection(sectionID, for: task)
            }
            quickAddText = ""
            // Focus stays in the field so several tasks can be typed in a row.
            Task { await remindersService.refreshAll() }
        } catch {
            remindersService.lastError = error.localizedDescription
        }
    }

    /// An explicit `#project` token wins; otherwise a project view adds to itself, and the
    /// date-based views fall back to the Reminders default list.
    private func resolveProjectID(_ parsed: String?) -> String? {
        if let parsed { return parsed }
        if case .project(let id) = selection { return id }
        let fallback = remindersService.defaultProjectID ?? remindersService.projects.first?.id
        return fallback?.isEmpty == false ? fallback : nil
    }

    // MARK: - Keyboard

    /// Bindings come from ShortcutsStore, which resolves the user's overrides over the Glaze
    /// build's defaults so muscle memory carries over until they change something.
    ///
    /// Returns true when the key was consumed. Anything typed into an add field is left alone, so
    /// shortcuts can be plain letters without eating task titles.
    private func handleEvent(_ event: NSEvent) -> Bool {
        RemitLog.debug("key code=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") editing=\(KeyMonitor.isEditingText) responder=\(String(describing: NSApp.keyWindow?.firstResponder))")
        // A snapshot launch takes keyboard focus while it draws; a key pressed then must not act.
        guard !KeyMonitor.isEditingText, !KeyMonitor.isRecording, !KeyMonitor.isSheetOpen,
              !DemoMode.isSnapshot else { return false }

        // macOS sets .function and .numericPad on arrow keys. Leaving them in the comparison
        // below made every arrow fail the "no modifiers" guard and fall through unhandled -- in
        // List view AppKit's table then moved the selection itself, which masked the bug until
        // Board (which has no table) showed arrows doing nothing at all.
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        if modifiers.contains(.command) {
            // ⌘K and ⌘Z are menu items now -- AppKit resolves those before this monitor runs.
            guard event.keyCode == 51 else { return false }   // Delete
            deleteSelected()
            return true
        }
        guard modifiers.isEmpty || modifiers == .shift else { return false }

        switch event.keyCode {
        case 125: moveSelection(.down); return true           // Down arrow
        case 126: moveSelection(.up); return true             // Up arrow
        case 123: moveColumn(-1); return true                 // Left arrow
        case 124: moveColumn(1); return true                  // Right arrow
        case 36:                                              // Return
            peekTask = ensureSelection()
            return true
        default: break
        }

        // Dispatch through the same store the Settings panel edits, so a rebind takes effect
        // immediately and there is no second copy of the table to drift (#74, and #76-#78 where a
        // shortcut was "added" but never actually wired).
        guard let action = shortcuts.action(matching: event) else { return false }
        perform(action)
        return true
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .nextTask: moveSelection(.down)
        case .previousTask: moveSelection(.up)
        case .completeTask: completeSelected()
        case .priority1: applyPriority(.p1)
        case .priority2: applyPriority(.p2)
        case .priority3: applyPriority(.p3)
        case .priority4: applyPriority(.p4)
        case .scheduleToday: schedule(.today)
        case .scheduleTomorrow: schedule(.tomorrow)
        case .scheduleWeekend: schedule(.weekend)
        case .scheduleNextWeek: schedule(.nextWeek)
        case .scheduleClear: schedule(.none)
        case .quickAdd: openFirstAddRow()
        case .editLabels: labelSheetTask = ensureSelection()
        case .openDetail: peekTask = ensureSelection()
        case .commandPalette: uiState.paletteOpen = true
        case .shortcutsPanel: uiState.shortcutsHelpOpen = true
        }
    }

    private var selectedTask: RemitTask? {
        guard let selectedTaskID else { return nil }
        return orderedTasks.first { $0.id == selectedTaskID }
    }

    /// Shortcuts that act on "the current task" need one selected. Falling back to the first row
    /// means pressing `e` or `t` on a freshly-opened list does the obvious thing instead of
    /// silently no-op'ing.
    @discardableResult
    private func ensureSelection() -> RemitTask? {
        if let selectedTask { return selectedTask }
        selectedTaskID = orderedTasks.first?.id
        return selectedTask
    }

    private func moveTasks(in section: TaskGrouping.Section, from source: IndexSet, to destination: Int) {
        guard sorting == .manual else {
            remindersService.lastError = "Switch Sorting to \"Manual\" in the Display menu to reorder tasks by hand."
            return
        }
        var ordered = section.tasks
        ordered.move(fromOffsets: source, toOffset: destination)
        metadataStore.setTaskOrder(ordered.map(\.id))
    }

    private func openFirstAddRow() {
        activeAddSection = sections.first { !$0.isOverdue }?.id
        focus = .quickAdd
    }

    /// Vertical movement. In List and Calendar this walks the flattened rendered order, so `j`
    /// crosses a section boundary the way the eye does. In Board it stays inside the current
    /// column -- a board's columns are parallel, not one continuous list, so falling from the
    /// bottom of one column into the top of the next reads as a bug.
    private func moveSelection(_ direction: MoveCommandDirection) {
        let tasks = layout == .board ? currentColumn?.tasks ?? [] : orderedTasks
        guard !tasks.isEmpty else {
            selectedTaskID = orderedTasks.first?.id
            return
        }

        guard let currentID = selectedTaskID,
              let currentIndex = tasks.firstIndex(where: { $0.id == currentID }) else {
            selectedTaskID = tasks.first?.id
            return
        }

        switch direction {
        case .down:
            let nextIndex = tasks.index(after: currentIndex)
            if nextIndex < tasks.count {
                selectedTaskID = tasks[nextIndex].id
            }
        case .up:
            if currentIndex > tasks.startIndex {
                selectedTaskID = tasks[tasks.index(before: currentIndex)].id
            }
        default:
            break
        }
    }

    /// The section whose column currently holds the selection.
    private var currentColumn: TaskGrouping.Section? {
        guard let selectedTaskID else { return sections.first { !$0.tasks.isEmpty } }
        return sections.first { $0.tasks.contains { $0.id == selectedTaskID } }
    }

    /// Left/right across board columns, keeping roughly the same row so the selection tracks
    /// horizontally instead of jumping to the top of every column. Empty columns are skipped --
    /// stopping on one would strand the selection with nothing to select.
    private func moveColumn(_ delta: Int) {
        guard layout == .board else { return }
        let populated = sections.enumerated().filter { !$0.element.tasks.isEmpty }
        guard !populated.isEmpty else { return }

        guard let selectedTaskID,
              let currentPosition = populated.firstIndex(where: { section in
                  section.element.tasks.contains { $0.id == selectedTaskID }
              }) else {
            self.selectedTaskID = populated.first?.element.tasks.first?.id
            return
        }

        let row = populated[currentPosition].element.tasks
            .firstIndex { $0.id == selectedTaskID } ?? 0
        let target = currentPosition + delta
        guard target >= 0, target < populated.count else { return }

        let column = populated[target].element.tasks
        self.selectedTaskID = column[min(row, column.count - 1)].id
    }

    /// Completing removes the row from every view that filters on `!isCompleted`, so the selection
    /// moves to the next task first -- otherwise it would point at a row that no longer exists and
    /// the next `j` would jump back to the top of the list.
    private func completeSelected() {
        guard let task = ensureSelection() else { return }
        let tasks = orderedTasks
        let successorID = tasks.firstIndex(where: { $0.id == task.id })
            .map { tasks.index(after: $0) }
            .flatMap { $0 < tasks.count ? tasks[$0].id : tasks.last(where: { $0.id != task.id })?.id }

        remindersService.completeAnimated(task)
        selectedTaskID = successorID
    }

    private func applyPriority(_ priority: Priority) {
        guard let task = ensureSelection() else { return }
        let previous = task.priority
        remindersService.recordUndo("priority") {
            try remindersService.setPriority(previous, for: task)
        }
        perform { try remindersService.setPriority(priority, for: task) }
    }

    private func schedule(_ target: ScheduleTarget) {
        guard let task = ensureSelection() else { return }
        let previous = task.dueDate
        remindersService.recordUndo("schedule") {
            try remindersService.setDueDate(previous, for: task)
        }
        perform { try remindersService.setDueDate(target.date, for: task) }
    }

    /// Moves every task in a column at once. One undo entry covers the whole batch and restores
    /// each task's own previous date -- a bulk edit you cannot take back in one step is worse than
    /// no bulk edit, since the dates it overwrote are exactly the information you would need to
    /// put them back by hand.
    private func rescheduleAll(in section: TaskGrouping.Section, to target: ScheduleTarget) {
        let tasks = section.tasks
        guard !tasks.isEmpty else { return }
        let previous = tasks.map { ($0, $0.dueDate) }

        remindersService.recordUndo("reschedule \(tasks.count) task\(tasks.count == 1 ? "" : "s")") {
            for (task, date) in previous {
                try remindersService.setDueDate(date, for: task)
            }
        }
        perform {
            for task in tasks {
                try remindersService.setDueDate(target.date, for: task)
            }
        }
    }

    private func deleteSelected() {
        guard let task = ensureSelection() else { return }
        perform { try remindersService.delete(task) }
        selectedTaskID = nil
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            Task { await remindersService.refreshAll() }
        } catch {
            remindersService.lastError = error.localizedDescription
        }
    }
}

/// Makes a row draggable only when a drag should move it between groups. Under Manual sort the
/// List's own reordering drag is used instead, and a second drag source on the row would fight it.
private struct TaskDrag: ViewModifier {
    let id: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(id)
        } else {
            content
        }
    }
}
