import Foundation

/// A Reminders-backed task, decorated with the Remit-only fields (section, sort order) that
/// EventKit has no native concept of. Those fields come from MetadataStore, not the reminder
/// itself -- see Services/MetadataStore.swift.
struct RemitTask: Identifiable, Hashable {
    /// EKReminder.calendarItemIdentifier -- stable across fetches, used as the join key into
    /// MetadataStore.
    let id: String
    var title: String
    var notes: String?
    var isCompleted: Bool
    var dueDate: Date?
    var hasDueTime: Bool
    var priority: Priority
    /// EKCalendar.calendarIdentifier of the reminder's list.
    var projectID: String
    var labels: [String]
    var sectionID: String?
    var sortOrder: Int
    var url: URL?
    var creationDate: Date?
}
