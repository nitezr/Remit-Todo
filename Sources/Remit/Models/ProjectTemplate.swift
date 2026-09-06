import Foundation

/// A saved project skeleton: its section names, and the labels it habitually uses.
///
/// Local save/apply only -- sharing templates with other people is explicitly out of scope for v1
/// (ROADMAP.md "Explicitly out of scope"). Tasks are never captured; a template is structure, not
/// content, so applying one to a busy project can't duplicate or overwrite work.
struct ProjectTemplate: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var sectionNames: [String]
    var labelNames: [String]
    var createdAt: Date
}

/// A user-defined filter. Reminders has no filter concept, so these are built from scratch in
/// Remit (#27) out of the same criteria the Display menu uses.
struct SavedFilter: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var deadline: DeadlineFilter
    /// Raw value of a Priority, or "all".
    var priority: String
    /// A label id, or "all".
    var labelID: String
    /// Restrict to one project, or nil for everywhere.
    var projectID: String?

    func matches(_ task: RemitTask, labelIDs: [String]) -> Bool {
        guard deadline.matches(task) else { return false }
        if priority != "all", String(task.priority.rawValue) != priority { return false }
        if labelID != "all", !labelIDs.contains(labelID) { return false }
        if let projectID, task.projectID != projectID { return false }
        return true
    }
}
