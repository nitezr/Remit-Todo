import SwiftUI

/// Grouping and date-formatting shared by Today, Upcoming, and project views.
///
/// Ported from the Glaze build's `renderer/lib/view-helpers.ts`. Everything here derives from
/// `RemitTask.dueDate` and the bucketing predicates in RemindersService, so there is still exactly
/// one answer to "what counts as due today" -- the divergence between Remit's counts and
/// Reminders.app's own counts bit the Electron build twice (ROADMAP.md "Known traps").
enum TaskGrouping {

    /// One rendered group of tasks: a header plus its rows.
    struct Section: Identifiable {
        let id: String
        let title: String
        var tasks: [RemitTask]
        /// The date this group represents, used as the default due date for its inline add row.
        var date: Date?
        /// Overdue is pinned above everything and never takes new tasks.
        var isOverdue: Bool = false
        /// A collapsed run of empty days, e.g. "Nothing until 12 Sep". Renders as a slim separator.
        var gapLabel: String?
        /// The named project section this group represents, if any. Date-based groups and the
        /// unsectioned bucket both leave this nil; `isSectionBucket` distinguishes them.
        var sectionID: String?
        /// True for any group in a project view, including the unsectioned bucket -- these accept
        /// tasks dropped or added into them, date groups reschedule instead.
        var isSectionBucket: Bool = false
    }

    // MARK: - Sorting

    /// Dated tasks first in date order, undated last, ties broken by priority. Matches
    /// `sortReminders` so a task doesn't sit in a different position in Today than in its project.
    static func sorted(_ tasks: [RemitTask]) -> [RemitTask] {
        tasks.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?):
                if left != right { return left < right }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return lhs.priority < rhs.priority
        }
    }

    // MARK: - Today

    /// Overdue (only when non-empty) above Today. Today always renders, so an empty Today still
    /// shows its header and inline add row rather than a blank pane.
    static func today(_ tasks: [RemitTask]) -> [Section] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        var sections: [Section] = []

        let overdue = tasks.filter { $0.isOverdue }
        if !overdue.isEmpty {
            sections.append(
                Section(id: "overdue", title: "Overdue", tasks: sorted(overdue), isOverdue: true)
            )
        }

        let dueToday = tasks.filter { $0.isDueToday }
        sections.append(
            Section(id: "today", title: "Today", tasks: sorted(dueToday), date: startOfToday)
        )
        return sections
    }

    // MARK: - Project

    /// A project splits into its named sections plus one unsectioned bucket. Sections are a
    /// Remit-only layer -- Reminders has no section primitive -- so the grouping is driven by
    /// MetadataStore rather than anything on the reminder itself (ROADMAP.md "Sections").
    ///
    /// The unsectioned bucket renders first and without a header when there are no named sections,
    /// so a project that has never used sections looks like a plain list.
    /// `assignments` maps a task id to the section it belongs to; a task absent from it is
    /// unsectioned. A section id that no longer exists also reads as unsectioned, so deleting a
    /// section can never hide its tasks.
    static func project(
        _ tasks: [RemitTask],
        sections projectSections: [TaskSection],
        assignments: [String: String],
        untitled: String
    ) -> [Section] {
        let sorted = sorted(tasks)
        let liveIDs = Set(projectSections.map(\.id))
        func sectionID(of task: RemitTask) -> String? {
            guard let id = assignments[task.id], liveIDs.contains(id) else { return nil }
            return id
        }

        var result: [Section] = [
            Section(
                id: "unsectioned",
                title: projectSections.isEmpty ? untitled : "(No section)",
                tasks: sorted.filter { sectionID(of: $0) == nil },
                isSectionBucket: true
            )
        ]

        for section in projectSections {
            result.append(
                Section(
                    id: section.id,
                    title: section.name,
                    tasks: sorted.filter { sectionID(of: $0) == section.id },
                    sectionID: section.id,
                    isSectionBucket: true
                )
            )
        }
        return result
    }

    // MARK: - Upcoming

    /// Days 0-6 always render, empty or not (Todoist muscle memory). Past the first week only days
    /// that actually have tasks appear, and a run of empty days collapses into one "Nothing until
    /// ..." separator rather than an endless column of empty headers.
    static func upcoming(_ tasks: [RemitTask]) -> [Section] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        var sections: [Section] = []

        let overdue = tasks.filter { $0.isOverdue }
        if !overdue.isEmpty {
            sections.append(
                Section(id: "overdue", title: "Overdue", tasks: sorted(overdue), isOverdue: true)
            )
        }

        var byDay: [Date: [RemitTask]] = [:]
        for task in tasks where !task.isOverdue {
            guard let due = task.dueDate else { continue }
            byDay[calendar.startOfDay(for: due), default: []].append(task)
        }

        for offset in 0..<denseDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            sections.append(
                Section(
                    id: dayKey(day),
                    title: dayTitle(day, offset: offset),
                    tasks: sorted(byDay[day] ?? []),
                    date: day
                )
            )
        }

        // Everything past the dense window, in date order, with gaps collapsed.
        let laterDays = byDay.keys
            .filter { $0 >= calendar.date(byAdding: .day, value: denseDays, to: startOfToday) ?? startOfToday }
            .sorted()
        var previousDay = calendar.date(byAdding: .day, value: denseDays - 1, to: startOfToday)
        for day in laterDays {
            var gap: String?
            if let previousDay,
               let dayGap = calendar.dateComponents([.day], from: previousDay, to: day).day,
               dayGap > 1 {
                gap = "Nothing until \(shortDate(day))"
            }
            let offset = calendar.dateComponents([.day], from: startOfToday, to: day).day ?? 0
            sections.append(
                Section(
                    id: dayKey(day),
                    title: dayTitle(day, offset: offset),
                    tasks: sorted(byDay[day] ?? []),
                    date: day,
                    gapLabel: gap
                )
            )
            previousDay = day
        }
        return sections
    }

    private static let denseDays = 7

    // MARK: - Explicit grouping

    /// Group-by chosen in the Display menu, overriding a view's natural sections. Empty groups are
    /// dropped -- a "Priority 3" header with nothing under it is noise.
    static func grouped(
        _ tasks: [RemitTask],
        by groupBy: TaskGroupBy,
        projects: [RemitProject],
        labelsFor: (RemitTask) -> [RemitLabel],
        untitled: String
    ) -> [Section] {
        switch groupBy {
        case .default:
            return []
        case .none:
            return [Section(id: "all", title: untitled, tasks: tasks)]

        case .priority:
            return Priority.allCases.compactMap { priority in
                let matching = tasks.filter { $0.priority == priority }
                guard !matching.isEmpty else { return nil }
                return Section(id: "p\(priority.rawValue)", title: priority.label, tasks: matching)
            }

        case .project:
            return projects.compactMap { project in
                let matching = tasks.filter { $0.projectID == project.id }
                guard !matching.isEmpty else { return nil }
                return Section(id: project.id, title: project.title, tasks: matching)
            }

        case .dueDate:
            var byDay: [Date: [RemitTask]] = [:]
            var undated: [RemitTask] = []
            for task in tasks {
                if let due = task.dueDate {
                    byDay[Calendar.current.startOfDay(for: due), default: []].append(task)
                } else {
                    undated.append(task)
                }
            }
            let today = Calendar.current.startOfDay(for: Date())
            var result = byDay.keys.sorted().map { day -> Section in
                let offset = Calendar.current.dateComponents([.day], from: today, to: day).day ?? 0
                return Section(
                    id: dayKey(day),
                    title: dayTitle(day, offset: offset),
                    tasks: byDay[day] ?? [],
                    date: day
                )
            }
            if !undated.isEmpty {
                result.append(Section(id: "nodate", title: "No date", tasks: undated))
            }
            return result

        case .label:
            var byLabel: [String: (RemitLabel, [RemitTask])] = [:]
            var unlabelled: [RemitTask] = []
            for task in tasks {
                let labels = labelsFor(task)
                if labels.isEmpty {
                    unlabelled.append(task)
                }
                for label in labels {
                    byLabel[label.id, default: (label, [])].1.append(task)
                }
            }
            var result = byLabel.values
                .sorted { $0.0.order < $1.0.order }
                .map { Section(id: $0.0.id, title: $0.0.name, tasks: $0.1) }
            if !unlabelled.isEmpty {
                result.append(Section(id: "nolabel", title: "No label", tasks: unlabelled))
            }
            return result
        }
    }

    // MARK: - Formatting

    /// Todoist's day heading: "28 Aug · Today · Friday", dropping the relative word past tomorrow.
    static func dayTitle(_ date: Date, offset: Int) -> String {
        let weekday = date.formatted(.dateTime.weekday(.wide))
        let dayMonth = shortDate(date)
        // The relative name *replaces* the weekday rather than joining it. "6 Sep · Today · Sunday"
        // says the same thing twice; the reference reads "6 Sep · Today".
        switch offset {
        case 0: return "\(dayMonth) · Today"
        case 1: return "\(dayMonth) · Tomorrow"
        default: return "\(dayMonth) · \(weekday)"
        }
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    private static func dayKey(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    /// The trailing date pill on a task row. Overdue reads red, today green, everything else
    /// secondary -- the same three-colour scheme as `dueDateBadge` in the Glaze build.
    static func dueBadge(for task: RemitTask) -> (label: String, color: Color)? {
        guard let dueDate = task.dueDate else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: dueDate)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0

        // Midnight is a date, not a time. Reminders records plenty of ordinary dated tasks at
        // 00:00 with an hour component, so hasDueTime is true for them -- printing "12:00 AM"
        // against every one of those is noise, and the same false positive that had the
        // sleeping-hours filter hiding them.
        let components = calendar.dateComponents([.hour, .minute], from: dueDate)
        let isMidnight = components.hour == 0 && (components.minute ?? 0) == 0
        let time = (task.hasDueTime && !isMidnight)
            ? " \(dueDate.formatted(.dateTime.hour().minute()))"
            : ""

        switch days {
        case ..<0:
            return (days == -1 ? "Yesterday" : shortDate(dueDate), .red)
        case 0:
            return ("Today" + time, .green)
        case 1:
            return ("Tomorrow" + time, .secondary)
        case 2..<7:
            return (dueDate.formatted(.dateTime.weekday(.wide)) + time, .secondary)
        default:
            return (shortDate(dueDate) + time, .secondary)
        }
    }
}

private extension Color {
    /// `.secondary` is a ShapeStyle rather than a Color, so the badge needs a concrete stand-in.
    static let secondary = Color(nsColor: .secondaryLabelColor)
}
