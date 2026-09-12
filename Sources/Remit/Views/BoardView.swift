import SwiftUI

/// Kanban layout: one column per section, cards inside.
///
/// The Electron build had a real bug here -- moving a task from Tomorrow to Today made it vanish
/// instead of appearing in the Today column, because the board's date buckets were only recomputed
/// on reload (ROADMAP.md #7). This view holds no bucket state of its own: `columns` is derived from
/// the same `TaskGrouping.Section` list the List layout uses, so a move that changes a task's date
/// or section is reflected on the next render with nothing to invalidate.
struct BoardView<TaskMenu: View>: View {
    let sections: [TaskGrouping.Section]
    let showsProject: Bool
    /// Board has no List to draw selection for it, so the selected card is highlighted here --
    /// otherwise j/k/e/t all fire correctly but appear to do nothing.
    @Binding var selectedTaskID: String?
    /// Nil in views where sections aren't a concept (Today, Upcoming), which hides the add column.
    var onAddSection: ((String) -> Void)?
    var onDrop: (RemitTask, TaskGrouping.Section) -> Void

    @State private var newSectionName = ""
    @State private var addingSection = false

    /// Adds a task to a column. Nil hides the affordance, which is right for a board whose columns
    /// aren't somewhere a task can be created (Overdue means nothing as a destination).
    var onAddTask: ((TaskGrouping.Section) -> Void)?
    /// Title shown above the columns. Nil renders the board with no header at all, which is what a
    /// project board wants -- its name is already in the window title.
    var boardTitle: String?
    /// Bulk-moves every task in a column to a new date. Offered only on Overdue, where a pile of
    /// stale dates is the normal state and moving them one at a time is the whole problem.
    var onRescheduleAll: ((TaskGrouping.Section, ScheduleTarget) -> Void)?
    /// The list layout's task menu, reused verbatim. A board card is the same task, so growing a
    /// second menu here would mean two places to keep in step.
    @ViewBuilder var taskMenu: (RemitTask) -> TaskMenu

    var body: some View {
        VStack(spacing: 0) {
            if let boardTitle {
                header(boardTitle)
                Divider().overlay(Theme.separator)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 26) {
                        ForEach(sections) { section in
                            column(section).id(section.id)
                        }
                        if onAddSection != nil {
                            addSectionColumn
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                .background(Theme.pageBackground)
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .leading) }
                    scrollTarget = nil
                }
            }
        }
    }

    @State private var scrollTarget: String?

    /// Mirrors the reference: a large view title, the month the columns fall in beneath it, and a
    /// prev / Today / next control on the trailing edge. The arrows move the viewport rather than a
    /// date window -- this board is built from "today onwards", so there is nothing else to page.
    private func header(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.font(26, .bold))
                    .foregroundStyle(Theme.primaryText)
                Text(monthLabel)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer()

            HStack(spacing: 0) {
                stepButton(systemImage: "chevron.left", step: -1)
                Divider().frame(height: 16).overlay(Theme.separator)
                Button("Today") { scrollTarget = todayColumnID }
                    .buttonStyle(.plain)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                Divider().frame(height: 16).overlay(Theme.separator)
                stepButton(systemImage: "chevron.right", step: 1)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.separator, lineWidth: 1)
            )
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(Theme.pageBackground)
    }

    private func stepButton(systemImage: String, step: Int) -> some View {
        Button {
            guard let current = visibleAnchorIndex else { return }
            let next = min(max(current + step, 0), sections.count - 1)
            scrollTarget = sections[next].id
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var todayColumnID: String? {
        sections.first { $0.date.map { Calendar.current.isDateInToday($0) } ?? false }?.id
    }

    private var visibleAnchorIndex: Int? {
        guard let todayColumnID else { return sections.isEmpty ? nil : 0 }
        return sections.firstIndex { $0.id == todayColumnID }
    }

    private var monthLabel: String {
        let dated = sections.compactMap(\.date).sorted()
        let reference = dated.first ?? Date()
        return reference.formatted(.dateTime.month(.wide).year())
    }

    /// Board needs its own section-creation affordance -- the List layout's "Add section" row
    /// isn't reachable from here.
    @ViewBuilder
    private var addSectionColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if addingSection {
                TextField("Section name", text: $newSectionName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let name = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { onAddSection?(name) }
                        newSectionName = ""
                        addingSection = false
                    }
                    .onExitCommand {
                        newSectionName = ""
                        addingSection = false
                    }
            } else {
                Button {
                    addingSection = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Add section")
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 220)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    private func column(_ section: TaskGrouping.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Date and weekday carry the weight; the count sits beside them in secondary so it
            // reads as an annotation rather than a second title.
            HStack(spacing: 7) {
                Text(section.title)
                    .font(Theme.font(15, .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("\(section.tasks.count)")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
                Spacer(minLength: 0)

                if section.isOverdue, !section.tasks.isEmpty, let onRescheduleAll {
                    Menu("Reschedule") {
                        Button("Today") { onRescheduleAll(section, .today) }
                        Button("Tomorrow") { onRescheduleAll(section, .tomorrow) }
                        Button("This Weekend") { onRescheduleAll(section, .weekend) }
                        Button("Next Week") { onRescheduleAll(section, .nextWeek) }
                        Divider()
                        Button("Remove Due Date") { onRescheduleAll(section, ScheduleTarget.none) }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.accent)
                    .help("Move all \(section.tasks.count) overdue tasks to a new date")
                }
            }
            .padding(.horizontal, 2)
            .contextMenu { sectionContextMenu(section) }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(section.tasks) { task in
                            TaskCard(
                                task: task,
                                showsProject: showsProject,
                                isSelected: task.id == selectedTaskID
                            )
                            .id(task.id)
                            .draggable(task.id)
                            .onTapGesture { selectedTaskID = task.id }
                            .contextMenu { taskMenu(task) }
                        }

                        // Overdue is not a destination -- "add a task to Overdue" means nothing.
                        if let onAddTask, !section.isOverdue {
                            Button { onAddTask(section) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12))
                                    Text("Add task")
                                        .font(Theme.font(13))
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(Theme.secondaryText)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                // Keyboard navigation can move the selection into a column that's scrolled out of
                // view; follow it so j/k don't select something invisible.
                .onChange(of: selectedTaskID) {
                    guard let selectedTaskID,
                          section.tasks.contains(where: { $0.id == selectedTaskID }) else { return }
                    withAnimation { proxy.scrollTo(selectedTaskID, anchor: .center) }
                }
            }

            Spacer(minLength: 0)
        }
        // No column fill. The reference separates columns with whitespace alone; a tinted panel
        // behind each one competes with the cards, which are the only thing that should read as
        // a surface here.
        .frame(width: 290)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first,
                  let task = sections.flatMap(\.tasks).first(where: { $0.id == id }) else { return false }
            onDrop(task, section)
            return true
        }
    }

    @ViewBuilder
    private func sectionContextMenu(_ section: TaskGrouping.Section) -> some View {
        if let onAddTask, !section.isOverdue {
            Button("Add Task") { onAddTask(section) }
        }
    }
}

/// Board card. Kept visually distinct from a list row: bordered, padded, and metadata stacked
/// underneath rather than trailing, matching the reference screenshots (ROADMAP.md #14, #23).
struct TaskCard: View {
    let task: RemitTask
    var showsProject: Bool
    var isSelected: Bool = false

    @EnvironmentObject private var remindersService: RemindersService
    @EnvironmentObject private var metadataStore: MetadataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 9) {
                Button {
                    toggle()
                } label: {
                    Image(systemName: isCompleting || task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(priorityColor)
                        .scaleEffect(isCompleting ? 1.25 : 1)
                }
                .buttonStyle(.plain)
                .padding(.top, 0.5)

                Text(task.title)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            // Everything below the title is indented to the title's left edge, so the card reads
            // as one block hanging off the checkbox rather than three unrelated rows.
            VStack(alignment: .leading, spacing: 5) {
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(Theme.taskNotes)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if hasBadgeRow {
                    HStack(spacing: 8) {
                        if task.isRecurring {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        if let badge = TaskGrouping.dueBadge(for: task) {
                            Text(badge.label)
                                .font(Theme.taskMeta)
                                .foregroundStyle(badge.color)
                        }
                        ForEach(labels) { label in
                            // Tag glyph plus plain coloured text, not a filled pill: at card size a
                            // row of filled pills out-shouts the title above them.
                            HStack(spacing: 3) {
                                Image(systemName: "tag")
                                    .font(.system(size: 9))
                                Text(label.name)
                                    .font(Theme.taskMeta)
                            }
                            .foregroundStyle(label.color)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if showsProject, let project {
                    HStack(spacing: 5) {
                        Text("#")
                            .font(Theme.taskMeta)
                            .foregroundStyle(Color(hex: project.colorHex))
                        Text(project.title)
                            .font(Theme.taskMeta)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.leading, 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.cardBackground)
                .shadow(color: Theme.cardShadow, radius: 2.5, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? Theme.accent.opacity(0.55) : Theme.separator,
                    lineWidth: 1
                )
        )
        .opacity(isCompleting ? 0.35 : 1)
        .animation(.easeOut(duration: 0.3), value: isCompleting)
    }

    private var labels: [ReminderTag] {
        task.labels.map(ReminderTag.init(name:))
    }

    private var hasBadgeRow: Bool {
        task.isRecurring || TaskGrouping.dueBadge(for: task) != nil || !labels.isEmpty
    }

    private var project: RemitProject? {
        remindersService.projects.first { $0.id == task.projectID }
    }

    private var isCompleting: Bool {
        remindersService.completingIDs.contains(task.id)
    }

    private func toggle() {
        remindersService.completeAnimated(task)
    }

    private var priorityColor: Color { Theme.priority(task.priority) }
}
