import SwiftUI

/// Layout, grouping, sorting, and filtering for a view. Available consistently on every view
/// rather than only some -- the Electron build shipped view options on a subset of views and it
/// was reported twice (ROADMAP.md #15, #26).
enum TaskLayout: String, CaseIterable, Identifiable, Codable {
    case list, board, calendar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .board: return "Board"
        case .calendar: return "Calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .board: return "rectangle.split.3x1"
        case .calendar: return "calendar"
        }
    }
}

/// What the view's section headers are cut by. `.default` keeps each view's natural grouping --
/// Overdue/Today, the day rows of Upcoming, a project's own sections.
enum TaskGroupBy: String, CaseIterable, Identifiable, Codable {
    case `default`, none, dueDate, priority, label, project

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: return "Default"
        case .none: return "None"
        case .dueDate: return "Due date"
        case .priority: return "Priority"
        case .label: return "Label"
        case .project: return "Project"
        }
    }
}

/// How much time the Calendar layout shows at once.
enum CalendarRange: String, CaseIterable, Identifiable, Codable {
    case day, threeDays, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "Day"
        case .threeDays: return "3 Days"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    /// Days shown side by side. Month is the odd one out and renders as a grid instead.
    var dayCount: Int {
        switch self {
        case .day: return 1
        case .threeDays: return 3
        case .week: return 7
        case .month: return 0
        }
    }
}

enum TaskSorting: String, CaseIterable, Identifiable, Codable {
    case smart, manual, dueDate, priority, alphabetical, added

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smart: return "Smart"
        case .manual: return "Manual (drag to order)"
        case .dueDate: return "Due date"
        case .priority: return "Priority"
        case .alphabetical: return "Alphabetical"
        case .added: return "Date added"
        }
    }

    func apply(_ tasks: [RemitTask]) -> [RemitTask] {
        switch self {
        case .smart:
            return TaskGrouping.sorted(tasks)
        case .manual:
            // Ordering is applied by the caller, which has the metadata store; leaving the input
            // order untouched here keeps this enum free of store dependencies.
            return tasks
        case .dueDate:
            return tasks.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        case .priority:
            return tasks.sorted { $0.priority < $1.priority }
        case .alphabetical:
            return tasks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .added:
            return tasks.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        }
    }
}

enum DeadlineFilter: String, CaseIterable, Identifiable, Codable {
    case all, overdue, today, thisWeek, noDate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .thisWeek: return "Next 7 days"
        case .noDate: return "No date"
        }
    }

    func matches(_ task: RemitTask) -> Bool {
        let calendar = Calendar.current
        switch self {
        case .all:
            return true
        case .overdue:
            return task.isOverdue
        case .today:
            return task.isDueToday
        case .thisWeek:
            guard let due = task.dueDate else { return false }
            let today = calendar.startOfDay(for: Date())
            guard let limit = calendar.date(byAdding: .day, value: 7, to: today) else { return false }
            return due >= today && due < limit
        case .noDate:
            return task.dueDate == nil
        }
    }
}

/// The Display popover: layout, grouping, sorting, and filters, laid out to match the reference
/// screenshot rather than as a plain menu -- grouped headings, inline pickers, and a reset.
struct DisplayMenu: View {
    @Binding var layout: TaskLayout
    @Binding var groupBy: TaskGroupBy
    @Binding var sorting: TaskSorting
    @Binding var showsCompleted: Bool
    @Binding var deadline: DeadlineFilter
    @Binding var priorityFilter: String
    @Binding var labelFilter: String
    let labels: [RemitLabel]
    var onReset: () -> Void
    /// Nil where saving isn't meaningful (the Filters & Labels page itself).
    var onSaveFilter: ((String) -> Void)?

    @State private var savingFilter = false
    @State private var filterName = ""

    @State private var isPresented = false

    /// Counts the options differing from their defaults, shown as a badge so it's obvious when a
    /// view is filtered -- otherwise a filter left on looks like missing data.
    private var activeCount: Int {
        var count = 0
        if groupBy != .default { count += 1 }
        if sorting != .smart { count += 1 }
        if showsCompleted { count += 1 }
        if deadline != .all { count += 1 }
        if priorityFilter != "all" { count += 1 }
        if labelFilter != "all" { count += 1 }
        return count
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text("Display")
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content
                .frame(width: 320)
                .padding(14)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Layout")
                .font(.system(size: 13, weight: .semibold))

            Picker("", selection: $layout) {
                ForEach(TaskLayout.allCases) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle("Completed tasks", isOn: $showsCompleted)
                .toggleStyle(.switch)

            Divider()

            Text("Sort")
                .font(.system(size: 13, weight: .semibold))
            row("Grouping", changed: groupBy != .default) {
                Picker("", selection: $groupBy) {
                    ForEach(TaskGroupBy.allCases) { Text($0.label).tag($0) }
                }
            }
            row("Sorting", changed: sorting != .smart) {
                Picker("", selection: $sorting) {
                    ForEach(TaskSorting.allCases) { Text($0.label).tag($0) }
                }
            }

            Divider()

            Text("Filter")
                .font(.system(size: 13, weight: .semibold))
            row("Deadline", changed: deadline != .all) {
                Picker("", selection: $deadline) {
                    ForEach(DeadlineFilter.allCases) { Text($0.label).tag($0) }
                }
            }
            row("Priority", changed: priorityFilter != "all") {
                Picker("", selection: $priorityFilter) {
                    Text("All").tag("all")
                    ForEach(Priority.allCases) { Text($0.label).tag(String($0.rawValue)) }
                }
            }
            row("Label", changed: labelFilter != "all") {
                Picker("", selection: $labelFilter) {
                    Text("All").tag("all")
                    ForEach(labels) { Text($0.name).tag($0.id) }
                }
            }

            Divider()

            if let onSaveFilter {
                if savingFilter {
                    HStack(spacing: 6) {
                        TextField("Filter name", text: $filterName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                let name = filterName.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !name.isEmpty { onSaveFilter(name) }
                                filterName = ""
                                savingFilter = false
                            }
                        Button("Cancel") { savingFilter = false; filterName = "" }
                            .buttonStyle(.link)
                    }
                } else {
                    Button("Save as Filter...") { savingFilter = true }
                        .buttonStyle(.link)
                        .disabled(deadline == .all && priorityFilter == "all" && labelFilter == "all")
                }
            }

            HStack {
                Spacer()
                Button("Reset all", role: .destructive, action: onReset)
                    .buttonStyle(.link)
                Spacer()
            }
        }
    }

    /// A labelled control row. The dot marks a setting that's been changed from its default, so a
    /// collapsed popover still tells you which knob is responsible for what you're seeing.
    private func row<Content: View>(
        _ title: String,
        changed: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            HStack(spacing: 4) {
                Text(title)
                if changed {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
            }
            Spacer()
            content()
                .labelsHidden()
                .frame(width: 170)
        }
    }
}
