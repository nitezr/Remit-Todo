import Foundation

/// A Reminders list, decorated with the Remit-only fields (emoji, custom color, nesting,
/// favorite, explicit sort order) that EventKit reminder lists don't support.
struct RemitProject: Identifiable, Hashable {
    /// EKCalendar.calendarIdentifier.
    let id: String
    var title: String
    /// Hex string derived from EKCalendar.cgColor, overridable via MetadataStore.
    var colorHex: String
    var emoji: String?
    var isFavorite: Bool
    var sortOrder: Int
    /// Remit-only nesting -- EventKit reminder lists cannot nest.
    var parentID: String?
}
