import Foundation

/// A section inside a Reminders list, exactly as Reminders stores it. Read from Reminders' store and
/// created, renamed and deleted through ReminderKit, so Remit and Reminders.app show the same ones.
struct TaskSection: Identifiable, Hashable {
    /// ReminderKit's section identifier.
    let id: String
    /// EKCalendar.calendarIdentifier of the list the section belongs to.
    var projectID: String
    var name: String
    var sortOrder: Int
}
