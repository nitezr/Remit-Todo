import Foundation

/// One task in the practice list the welcome tour can add.
struct TourTask: Identifiable {
    let section: String
    let title: String
    let notes: String
    var tags: [String] = []
    var dueToday = false
    var priority: Priority = .p4

    var id: String { title }
}

/// The practice list the welcome tour offers to add to Reminders.
///
/// Each task teaches one thing, using the default keys. Every person and project in it -- Sam,
/// Priya, Acme -- is made up, so the list reads the same for everyone and nothing personal turns up
/// in screenshots of it. Deleting the list removes the tags it introduced along with it.
enum TourContent {
    static let listName = "👋 Remit Tour"

    static let sections = ["1 · Basics", "2 · Organise", "3 · Power moves"]

    static let tasks: [TourTask] = [
        TourTask(
            section: sections[0],
            title: "Complete me: click the circle, or select me and press E",
            notes: "Completed tasks leave the list with a sound. ⌘Z brings the last one back.",
            dueToday: true
        ),
        TourTask(
            section: sections[0],
            title: "Press T to schedule me for today, or U for tomorrow",
            notes: "W is this weekend, N is next week, and 0 clears the date."
        ),
        TourTask(
            section: sections[0],
            title: "Double-click me, or press I, to open my details",
            notes: "Title, notes, date, repeat, priority, tags and section are all editable there."
        ),
        TourTask(
            section: sections[1],
            title: "Check in with Sam about the Acme launch plan",
            notes: "People are tags ending in 👤. ⏳waiting marks something you're waiting on someone else for.",
            tags: ["Sam👤", "⏳waiting"],
            dueToday: true,
            priority: .p2
        ),
        TourTask(
            section: sections[1],
            title: "Press L and add the 💬discuss tag to me",
            notes: "Tags live in Apple Reminders, so they show up on your iPhone too."
        ),
        TourTask(
            section: sections[1],
            title: "Move me to another section: right-click, then Move to Section",
            notes: "Or pick Board in the Display menu and drag me between columns."
        ),
        TourTask(
            section: sections[2],
            title: "Press Q and type: Call Priya tomorrow 5pm p1 @Priya👤",
            notes: "Quick add understands dates, times, priorities (p1 to p4), #project and @tag."
        ),
        TourTask(
            section: sections[2],
            title: "Press ⌘K to search and jump to any project or task",
            notes: "Press ? any time for every keyboard shortcut. Change them in Settings."
        ),
        TourTask(
            section: sections[2],
            title: "Done? Right-click 👋 Remit Tour in the sidebar and delete it",
            notes: "That removes this list and its tasks from Reminders on every device, and the tour's tags with them."
        ),
    ]
}
