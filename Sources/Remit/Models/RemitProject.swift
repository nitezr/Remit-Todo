import Foundation

/// A Reminders list, decorated with the Remit-only presentation fields (emoji, favourite, sort
/// order) that neither EventKit nor Reminders has anywhere to store.
struct RemitProject: Identifiable, Hashable {
    /// EKCalendar.calendarIdentifier.
    let id: String
    var title: String
    /// Hex string derived from EKCalendar.cgColor, overridable via MetadataStore.
    var colorHex: String
    var emoji: String?
    var isFavorite: Bool
    var sortOrder: Int
    /// The Reminders group ("Personal", "Work") this list sits in, or nil at top level. Reminders' own
    /// grouping, read from its store -- EventKit doesn't expose it.
    var groupID: String?
}

/// A Reminders list group: a folder of lists in Reminders.app's sidebar. A group holds lists, never
/// tasks, so it is not a project and is never selectable.
struct ListGroup: Identifiable, Hashable {
    let id: String
    var name: String
    var projectIDs: [String]
}
