import Foundation

/// Everything Remit tracks that EventKit has nowhere to store: section assignment, project
/// emoji/color overrides, nesting, favorites, sort order. Persisted as one JSON file in
/// Application Support. Keys are EKCalendar.calendarIdentifier / EKReminder.calendarItemIdentifier
/// so this stays a pure decoration layer on top of the real Reminders data -- deleting this file
/// loses none of the user's actual tasks.
struct RemitMetadata: Codable {
    var projects: [String: ProjectMetadata] = [:]
    var tasks: [String: TaskMetadata] = [:]
    var sections: [TaskSection] = []
    var favoriteProjectIDs: [String] = []
}

struct ProjectMetadata: Codable {
    var emoji: String?
    var colorHexOverride: String?
    var sortOrder: Int = 0
    var parentID: String?
}

struct TaskMetadata: Codable {
    var sectionID: String?
    var sortOrder: Int = 0
}

@MainActor
final class MetadataStore: ObservableObject {
    @Published private(set) var data: RemitMetadata

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Remit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("metadata.json")

        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(RemitMetadata.self, from: raw) {
            data = decoded
        } else {
            data = RemitMetadata()
        }
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }

    func setSection(_ sectionID: String?, forTask taskID: String) {
        var meta = data.tasks[taskID] ?? TaskMetadata()
        meta.sectionID = sectionID
        data.tasks[taskID] = meta
        persist()
    }

    func addSection(name: String, toProject projectID: String) -> TaskSection {
        let section = TaskSection(
            id: UUID().uuidString,
            projectID: projectID,
            name: name,
            sortOrder: data.sections.filter { $0.projectID == projectID }.count
        )
        data.sections.append(section)
        persist()
        return section
    }

    func removeSection(_ sectionID: String) {
        data.sections.removeAll { $0.id == sectionID }
        for (taskID, var meta) in data.tasks where meta.sectionID == sectionID {
            meta.sectionID = nil
            data.tasks[taskID] = meta
        }
        persist()
    }

    func sections(forProject projectID: String) -> [TaskSection] {
        data.sections
            .filter { $0.projectID == projectID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func toggleFavorite(_ projectID: String) {
        if data.favoriteProjectIDs.contains(projectID) {
            data.favoriteProjectIDs.removeAll { $0 == projectID }
        } else {
            data.favoriteProjectIDs.append(projectID)
        }
        persist()
    }

    func setEmoji(_ emoji: String?, forProject projectID: String) {
        var meta = data.projects[projectID] ?? ProjectMetadata()
        meta.emoji = emoji
        data.projects[projectID] = meta
        persist()
    }

    func projectMetadata(_ projectID: String) -> ProjectMetadata {
        data.projects[projectID] ?? ProjectMetadata()
    }
}
