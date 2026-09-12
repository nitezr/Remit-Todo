import Foundation

/// A Reminders task. Title, dates, priority and list come from EventKit; tags and section come from
/// Reminders' own store (RemindersNative), because EventKit exposes neither.
struct RemitTask: Identifiable, Hashable {
    /// EKReminder.calendarItemIdentifier. It is also the reminder's ReminderKit identifier, which is
    /// what joins a task to its tags and section without any mapping table.
    let id: String
    var title: String
    var notes: String?
    var isCompleted: Bool
    var dueDate: Date?
    var hasDueTime: Bool
    var priority: Priority
    /// EKCalendar.calendarIdentifier of the reminder's list.
    var projectID: String
    /// Reminders tag names.
    var labels: [String]
    /// The Reminders section the task sits in, or nil when it is unsectioned.
    var sectionID: String?
    var sortOrder: Int
    /// EventKit owns the recurrence rule; Remit only needs to know one exists, to show the badge
    /// a repeating task carries on its card.
    var isRecurring: Bool
    var url: URL?
    var creationDate: Date?
}
