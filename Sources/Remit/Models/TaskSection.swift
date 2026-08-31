import Foundation

/// A Todoist-style section within a project. Purely a Remit-layer concept, persisted in
/// MetadataStore -- Apple Reminders has no section primitive. See ROADMAP.md "Sections".
struct TaskSection: Identifiable, Hashable, Codable {
    let id: String
    var projectID: String
    var name: String
    var sortOrder: Int
}
