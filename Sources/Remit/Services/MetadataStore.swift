import Foundation

/// The Remit-only presentation layer: project emoji and colour overrides, sort order, favourites,
/// saved filters and templates -- things neither EventKit nor Reminders has anywhere to store.
/// Persisted as one JSON file in Application Support, keyed by EventKit identifiers.
///
/// Tags, sections and list groups are deliberately *not* here. They used to be, as a parallel
/// system Reminders.app could not see; they are now read from and written to Reminders itself
/// (RemindersService), so there is exactly one set of each and both apps agree on it. Deleting this
/// file loses presentation choices only -- never a task, a tag or a section.
struct RemitMetadata: Codable {
    /// Bumped only when a field changes *meaning*. Merely adding a field needs no bump -- that
    /// case is handled by the tolerant decoder below. 0 means "written before versioning existed";
    /// 2 retired Remit's own labels, sections and nesting in favour of Reminders' native ones.
    static let currentSchemaVersion = 2

    var schemaVersion: Int = RemitMetadata.currentSchemaVersion
    var projects: [String: ProjectMetadata] = [:]
    var tasks: [String: TaskMetadata] = [:]
    var favoriteProjectIDs: [String] = []
    var templates: [ProjectTemplate] = []
    var filters: [SavedFilter] = []
}

extension RemitMetadata {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, tasks, favoriteProjectIDs, templates, filters
    }

    /// Decoded field by field with defaults, rather than by the synthesised initialiser, which
    /// throws on the first missing key.
    ///
    /// That difference is the entire point. This file gains fields as Remit grows, and under
    /// synthesised decoding every addition makes an older file undecodable. Paired with a loader
    /// that fell back to an empty store, an undecodable file meant the next write silently erased
    /// everything the user had. Decoding tolerantly here, and quarantining rather than overwriting
    /// in `MetadataStore.load`, are the two halves of making that failure impossible.
    ///
    /// Keys this build no longer declares -- schema 1's `labels`, `labelAssignments`,
    /// `labelFolders`, `sections`, and the `parentID`/`sectionID` fields -- are ignored on read and
    /// simply not written back. That is how that data is retired: no migration step can half-run.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        projects = try container.decodeIfPresent([String: ProjectMetadata].self, forKey: .projects) ?? [:]
        tasks = try container.decodeIfPresent([String: TaskMetadata].self, forKey: .tasks) ?? [:]
        favoriteProjectIDs = try container.decodeIfPresent([String].self, forKey: .favoriteProjectIDs) ?? []
        templates = try container.decodeIfPresent([ProjectTemplate].self, forKey: .templates) ?? []
        filters = try container.decodeIfPresent([SavedFilter].self, forKey: .filters) ?? []

        // Before schema 2 a filter named its label by a Remit UUID. Those labels are gone, and a
        // UUID can never equal a Reminders tag name, so the filter would quietly match nothing.
        // Widening it to any tag keeps the rest of its criteria working.
        if schemaVersion < 2 {
            for index in filters.indices where filters[index].labelID != "all" {
                filters[index].labelID = "all"
            }
        }
    }
}

struct ProjectMetadata: Codable {
    var emoji: String?
    var colorHexOverride: String?
    var sortOrder: Int = 0
}

struct TaskMetadata: Codable {
    var sortOrder: Int = 0
}

@MainActor
final class MetadataStore: ObservableObject {
    @Published private(set) var data: RemitMetadata

    private let fileURL: URL
    private let backupURL: URL

    /// Surfaced in the UI. Silent failure is the one thing this layer must never do: every
    /// quarantine, restore and failed write reports itself here.
    @Published var storageWarning: String?

    /// `directory` is injectable purely so the quarantine, backup and restore behaviour can be
    /// exercised against a temporary folder in tests rather than the user's real data.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("metadata.json")
        backupURL = dir.appendingPathComponent("metadata.backup.json")

        let outcome = Self.load(primary: fileURL, backup: backupURL)
        data = outcome.data
        storageWarning = outcome.warning
    }

    /// Loading never destroys evidence.
    ///
    /// A file that will not decode is moved aside with a timestamp, never overwritten, and the
    /// last known-good backup is tried before giving up. The previous implementation substituted
    /// an empty store on any read or decode failure, which meant the next `persist()` -- triggered
    /// by something as small as toggling one favourite -- wrote that emptiness over the real file.
    private static func load(primary: URL, backup: URL) -> (data: RemitMetadata, warning: String?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: primary.path) else {
            return (RemitMetadata(), nil) // ordinary first run
        }
        if let decoded = try? decode(primary) {
            return (decoded, nil)
        }

        // Unreadable. Preserve it before touching anything else.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let quarantine = primary.deletingLastPathComponent()
            .appendingPathComponent("metadata.corrupt-\(stamp).json")
        try? fm.moveItem(at: primary, to: quarantine)

        if let recovered = try? decode(backup) {
            return (
                recovered,
                "Remit could not read its metadata file, so the last good backup was restored. "
                    + "The unreadable copy was kept as \(quarantine.lastPathComponent)."
            )
        }
        return (
            RemitMetadata(),
            "Remit could not read its metadata file and no backup was available, so favourites, "
                + "filters, templates and project emoji have been reset. The unreadable "
                + "copy was kept as \(quarantine.lastPathComponent). Your Reminders lists, "
                + "tasks, tags and sections are untouched -- Remit has never stored them."
        )
    }

    private static func decode(_ url: URL) throws -> RemitMetadata {
        try JSONDecoder().decode(RemitMetadata.self, from: Data(contentsOf: url))
    }

    /// Wipes the Remit layer back to first-run state. Reminders data is untouched -- this store
    /// has never held a task or a list, only decorations keyed by their identifiers.
    func resetAll() {
        data = RemitMetadata()
        persist()
    }

    /// Rolls the current good file into the backup slot, then writes atomically, so there is
    /// never a moment with zero readable copies on disk. Reports failure instead of swallowing it.
    private func persist() {
        // Stamp the version being written, or a migrated file would be migrated again on every
        // load -- resetting any tag a filter was given since.
        if data.schemaVersion < RemitMetadata.currentSchemaVersion {
            data.schemaVersion = RemitMetadata.currentSchemaVersion
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let encoded = try? encoder.encode(data) else {
            storageWarning = "Remit could not encode its metadata, so the last change was not saved."
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
        }
        do {
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            storageWarning = "Remit could not save its metadata: \(error.localizedDescription)"
        }
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

    func isFavorite(_ projectID: String) -> Bool {
        data.favoriteProjectIDs.contains(projectID)
    }

    /// Drops every trace of a deleted project.
    func forgetProject(_ projectID: String, taskIDs: [String]) {
        data.projects[projectID] = nil
        data.favoriteProjectIDs.removeAll { $0 == projectID }
        for taskID in taskIDs {
            data.tasks[taskID] = nil
        }
        persist()
    }

    /// Explicit sibling order for projects. Stored as a sortOrder per project so the tree builder
    /// can sort siblings at every depth from one dictionary.
    func setProjectOrder(_ orderedIDs: [String]) {
        for (index, id) in orderedIDs.enumerated() {
            var meta = data.projects[id] ?? ProjectMetadata()
            meta.sortOrder = index
            data.projects[id] = meta
        }
        persist()
    }

    var projectOrder: [String] {
        data.projects
            .sorted { $0.value.sortOrder < $1.value.sortOrder }
            .map(\.key)
    }

    /// Manual task order within a group, used by the "Manual" sort option.
    func setTaskOrder(_ orderedIDs: [String]) {
        for (index, id) in orderedIDs.enumerated() {
            var meta = data.tasks[id] ?? TaskMetadata()
            meta.sortOrder = index
            data.tasks[id] = meta
        }
        persist()
    }

    func sortOrder(forTask taskID: String) -> Int {
        data.tasks[taskID]?.sortOrder ?? Int.max
    }

    // MARK: - Templates

    var templates: [ProjectTemplate] { data.templates }

    /// Captures a project's structure: its section names, which the caller reads from Reminders.
    /// See ProjectTemplate for why tasks are deliberately not part of a template. Applying one lives
    /// in RemindersService, because it creates real Reminders sections.
    @discardableResult
    func saveTemplate(name: String, sectionNames: [String]) -> ProjectTemplate? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let template = ProjectTemplate(
            id: UUID().uuidString,
            name: trimmed,
            sectionNames: sectionNames,
            createdAt: Date()
        )
        data.templates.append(template)
        persist()
        return template
    }

    func removeTemplate(_ templateID: String) {
        data.templates.removeAll { $0.id == templateID }
        persist()
    }

    // MARK: - Saved filters

    var filters: [SavedFilter] { data.filters }

    @discardableResult
    func addFilter(_ filter: SavedFilter) -> SavedFilter {
        data.filters.append(filter)
        persist()
        return filter
    }

    /// Replaces a filter in place, keeping its position so editing one does not reorder the list.
    func updateFilter(_ filter: SavedFilter) {
        guard let index = data.filters.firstIndex(where: { $0.id == filter.id }) else { return }
        data.filters[index] = filter
        persist()
    }

    func removeFilter(_ filterID: String) {
        data.filters.removeAll { $0.id == filterID }
        persist()
    }
}
