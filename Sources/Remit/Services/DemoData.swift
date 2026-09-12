import Foundation

/// The made-up workspace `--demo` shows: two Reminders groups, a few lists with sections, and a
/// week of work spread around today, so every layout has something to draw. All people, projects
/// and tasks are invented.
struct DemoData {
    static let inboxID = "demo-inbox"

    var projects: [RemitProject]
    var tasks: [RemitTask]
    var sections: [String: [TaskSection]]
    var groups: [ListGroup]
    var filters: [SavedFilter]
    var favoriteProjectIDs: [String]

    var tags: [ReminderTag] {
        Set(tasks.flatMap(\.labels))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(ReminderTag.init(name:))
    }

    func project(titled title: String) -> RemitProject? {
        projects.first { $0.title == title }
    }

    /// Dates are relative to `now`, so a screenshot taken on any day shows the same shape.
    static func sample(now: Date = Date()) -> DemoData {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        func list(_ id: String, _ title: String, _ color: String, group: String? = nil) -> RemitProject {
            RemitProject(id: id, title: title, colorHex: color, emoji: nil, isFavorite: false, sortOrder: 0, groupID: group)
        }

        let projects = [
            list(inboxID, "Inbox", "#FF8D28"),
            list("demo-acme", "🚀 Acme Launch", "#0088FF", group: "demo-work"),
            list("demo-orbit", "🌟 Orbit App", "#AF52DE", group: "demo-work"),
            list("demo-home", "🏠 Home", "#34C759", group: "demo-personal"),
            list("demo-finance", "💰 Finance", "#FF9500", group: "demo-personal"),
            list("demo-reading", "📚 Reading", "#5AC8FA", group: "demo-personal"),
            list("demo-side", "🌱 Side Project", "#FF2D55"),
        ]

        let groups = [
            ListGroup(id: "demo-work", name: "Work", projectIDs: ["demo-acme", "demo-orbit"]),
            ListGroup(id: "demo-personal", name: "Personal", projectIDs: ["demo-home", "demo-finance", "demo-reading"]),
        ]

        func sections(_ projectID: String, _ names: [String]) -> [TaskSection] {
            names.enumerated().map {
                TaskSection(id: "\(projectID)-s\($0.offset)", projectID: projectID, name: $0.element, sortOrder: $0.offset)
            }
        }
        let sectionMap = [
            "demo-acme": sections("demo-acme", ["Planning", "Design", "Launch week"]),
            "demo-orbit": sections("demo-orbit", ["Backlog", "In progress", "Review"]),
        ]

        var tasks: [RemitTask] = []
        func add(
            _ title: String,
            in projectID: String,
            section: Int? = nil,
            day: Int? = nil,
            at hour: Int? = nil,
            minute: Int = 0,
            priority: Priority = .p4,
            tags: [String] = [],
            notes: String? = nil,
            repeats: Bool = false
        ) {
            var due: Date?
            if let day, let base = calendar.date(byAdding: .day, value: day, to: today) {
                due = hour.flatMap { calendar.date(bySettingHour: $0, minute: minute, second: 0, of: base) } ?? base
            }
            tasks.append(RemitTask(
                id: "demo-task-\(tasks.count)",
                title: title,
                notes: notes,
                isCompleted: false,
                dueDate: due,
                hasDueTime: hour != nil,
                priority: priority,
                projectID: projectID,
                labels: tags,
                sectionID: section.map { "\(projectID)-s\($0)" },
                sortOrder: tasks.count,
                isRecurring: repeats,
                url: nil,
                creationDate: calendar.date(byAdding: .day, value: -tasks.count, to: today)
            ))
        }

        // Overdue
        add("Send Priya the signed contract", in: "demo-acme", section: 0, day: -2, priority: .p2, tags: ["Priya👤", "⏳waiting"])
        add("Renew passport appointment", in: "demo-home", day: -1, priority: .p3)

        // Today
        add("Finalize launch announcement copy", in: "demo-acme", section: 2, day: 0, at: 10, priority: .p1,
            tags: ["💬discuss"], notes: "Keep it under 150 words and lead with the problem.")
        add("Review Orbit onboarding designs", in: "demo-orbit", section: 2, day: 0, at: 14, priority: .p2, tags: ["Leo👤"])
        add("Check in with Sam about beta feedback", in: "demo-orbit", section: 1, day: 0, priority: .p3, tags: ["Sam👤", "⏳waiting"])
        add("Decide on the launch venue", in: "demo-acme", section: 0, day: 0, priority: .p2, tags: ["⚖️decision"])
        add("Pay the credit card bill", in: "demo-finance", day: 0, priority: .p1, repeats: true)
        add("Water the plants", in: "demo-home", day: 0, at: 18, repeats: true)

        // The coming week
        add("Prep slides for the Acme all-hands", in: "demo-acme", section: 2, day: 1, at: 11, priority: .p2)
        add("1:1 with Leo", in: "demo-orbit", day: 1, at: 15, minute: 30, tags: ["Leo👤", "💬discuss"])
        add("Grocery run", in: "demo-home", day: 1)
        add("Read chapter 4 of Deep Work", in: "demo-reading", day: 1)
        add("Fix sign-up form validation", in: "demo-orbit", section: 1, day: 2, priority: .p1)
        add("Book a dentist appointment", in: "demo-home", day: 2)
        add("Weekly review", in: inboxID, day: 2, at: 17, tags: ["🔁Weekly"], repeats: true)
        add("Draft the press kit", in: "demo-acme", section: 1, day: 3, priority: .p2)
        add("Move savings to the holiday fund", in: "demo-finance", day: 3, repeats: true)
        add("Record the product demo video", in: "demo-acme", section: 2, day: 4, priority: .p1, tags: ["Sam👤"])
        add("Ship Orbit 1.2 to TestFlight", in: "demo-orbit", section: 2, day: 6, priority: .p1)
        add("Launch day 🚀", in: "demo-acme", section: 2, day: 9, at: 9, priority: .p1)
        add("Quarterly taxes", in: "demo-finance", day: 12, priority: .p2)

        // Undated
        add("Pick the brand colour palette", in: "demo-acme", section: 1, priority: .p3, tags: ["Priya👤"])
        add("Compare email marketing tools", in: "demo-acme", section: 0, tags: ["⚖️decision"])
        add("Explore dark mode for Orbit", in: "demo-orbit", section: 0, tags: ["🗄️someday"])
        add("Try the new espresso place", in: inboxID)
        add("Ask Priya about the analytics vendor", in: inboxID, tags: ["Priya👤", "💬discuss"])
        add("Read The Design of Everyday Things", in: "demo-reading", tags: ["🗄️someday"])
        add("Write the Side Project README", in: "demo-side", priority: .p3)
        add("Sketch landing page ideas", in: "demo-side", tags: ["🗄️someday"])

        let filters = [
            SavedFilter(id: "demo-filter-waiting", name: "Waiting on others", deadline: .all,
                        priority: "all", labelID: "⏳waiting", projectID: nil),
            SavedFilter(id: "demo-filter-top", name: "Top priority this week", deadline: .thisWeek,
                        priority: String(Priority.p1.rawValue), labelID: "all", projectID: nil),
            SavedFilter(id: "demo-filter-decide", name: "Decisions to make", deadline: .all,
                        priority: "all", labelID: "⚖️decision", projectID: nil),
        ]

        return DemoData(
            projects: projects,
            tasks: tasks,
            sections: sectionMap,
            groups: groups,
            filters: filters,
            favoriteProjectIDs: ["demo-acme"]
        )
    }
}
