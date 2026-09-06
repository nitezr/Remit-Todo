import Foundation

/// Everything Remit tracks that EventKit has nowhere to store: section assignment, project
/// emoji/color overrides, nesting, favorites, sort order. Persisted as one JSON file in
/// Application Support. Keys are EKCalendar.calendarIdentifier / EKReminder.calendarItemIdentifier
/// so this stays a pure decoration layer on top of the real Reminders data -- deleting this file
/// loses none of the user's actual tasks.
struct RemitMetadata: Codable {
    /// Bumped only when a field changes *meaning*. Merely adding a field needs no bump -- that
    /// case is handled by the tolerant decoder below. 0 means "written before versioning existed".
    static let currentSchemaVersion = 1

    var schemaVersion: Int = RemitMetadata.currentSchemaVersion
    var projects: [String: ProjectMetadata] = [:]
    var tasks: [String: TaskMetadata] = [:]
    var sections: [TaskSection] = []
    var favoriteProjectIDs: [String] = []
    var labels: [RemitLabel] = []
    /// Task identifier -> label ids. Kept separate from `tasks` so a label can be deleted by
    /// sweeping one dictionary instead of walking every task's metadata.
    var labelAssignments: [String: [String]] = [:]
    var templates: [ProjectTemplate] = []
    var filters: [SavedFilter] = []
}

extension RemitMetadata {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, tasks, sections, favoriteProjectIDs
        case labels, labelAssignments, templates, filters
    }

    /// Decoded field by field with defaults, rather than by the synthesised initialiser, which
    /// throws on the first missing key.
    ///
    /// That difference is the entire point. This file gains fields as Remit grows -- `labels`,
    /// `labelAssignments`, `templates` and `filters` all arrived after v0.1 -- and under
    /// synthesised decoding every one of those additions makes an older file undecodable. Paired
    /// with a loader that fell back to an empty store, an undecodable file meant the next write
    /// silently erased every section, label, template, filter and project emoji the user had.
    /// Decoding tolerantly here, and quarantining rather than overwriting in `MetadataStore.load`,
    /// are the two halves of making that failure impossible.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        projects = try container.decodeIfPresent([String: ProjectMetadata].self, forKey: .projects) ?? [:]
        tasks = try container.decodeIfPresent([String: TaskMetadata].self, forKey: .tasks) ?? [:]
        sections = try container.decodeIfPresent([TaskSection].self, forKey: .sections) ?? []
        favoriteProjectIDs = try container.decodeIfPresent([String].self, forKey: .favoriteProjectIDs) ?? []
        labels = try container.decodeIfPresent([RemitLabel].self, forKey: .labels) ?? []
        labelAssignments = try container.decodeIfPresent([String: [String]].self, forKey: .labelAssignments) ?? [:]
        templates = try container.decodeIfPresent([ProjectTemplate].self, forKey: .templates) ?? []
        filters = try container.decodeIfPresent([SavedFilter].self, forKey: .filters) ?? []
    }
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
            "Remit could not read its metadata file and no backup was available, so sections, "
                + "labels, filters, templates and project emoji have been reset. The unreadable "
                + "copy was kept as \(quarantine.lastPathComponent). Your Reminders lists and "
                + "tasks are untouched -- Remit has never stored them."
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

    func isFavorite(_ projectID: String) -> Bool {
        data.favoriteProjectIDs.contains(projectID)
    }

    /// Setting a project's parent. Rejects anything that would create a cycle -- picking one of
    /// your own descendants as your parent would otherwise detach that whole branch from the tree.
    func setParent(_ parentID: String?, forProject projectID: String) {
        if let parentID {
            guard parentID != projectID,
                  !descendantIDs(of: projectID).contains(parentID) else { return }
        }
        var meta = data.projects[projectID] ?? ProjectMetadata()
        meta.parentID = parentID
        data.projects[projectID] = meta
        persist()
    }

    /// Every project below `projectID` in the tree, used to keep the parent picker cycle-free.
    func descendantIDs(of projectID: String) -> Set<String> {
        var childrenOf: [String: [String]] = [:]
        for (id, meta) in data.projects {
            if let parentID = meta.parentID { childrenOf[parentID, default: []].append(id) }
        }
        var result: Set<String> = []
        var stack = childrenOf[projectID] ?? []
        while let id = stack.popLast() {
            guard !result.contains(id) else { continue }
            result.insert(id)
            stack.append(contentsOf: childrenOf[id] ?? [])
        }
        return result
    }

    /// Drops every trace of a deleted project. Its children are promoted to top level rather than
    /// left pointing at a parent that no longer exists, which would silently hide them.
    func forgetProject(_ projectID: String, taskIDs: [String]) {
        data.projects[projectID] = nil
        data.favoriteProjectIDs.removeAll { $0 == projectID }
        data.sections.removeAll { $0.projectID == projectID }

        for (id, var meta) in data.projects where meta.parentID == projectID {
            meta.parentID = nil
            data.projects[id] = meta
        }
        for taskID in taskIDs {
            data.tasks[taskID] = nil
            data.labelAssignments[taskID] = nil
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

    /// Moves a section one place within its project. Sections are reordered rather than swapped so
    /// the stored orders stay dense and comparable.
    func moveSection(_ sectionID: String, by offset: Int) {
        guard let section = data.sections.first(where: { $0.id == sectionID }) else { return }
        var siblings = sections(forProject: section.projectID)
        guard let index = siblings.firstIndex(where: { $0.id == sectionID }) else { return }
        let target = index + offset
        guard target >= 0, target < siblings.count else { return }

        siblings.swapAt(index, target)
        for (order, sibling) in siblings.enumerated() {
            if let position = data.sections.firstIndex(where: { $0.id == sibling.id }) {
                data.sections[position].sortOrder = order
            }
        }
        persist()
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

    func renameSection(_ sectionID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = data.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        data.sections[index].name = trimmed
        persist()
    }

    // MARK: - Templates

    var templates: [ProjectTemplate] { data.templates }

    /// Captures a project's structure. Section names only -- see ProjectTemplate for why tasks
    /// are deliberately not part of a template.
    @discardableResult
    func saveTemplate(name: String, fromProject projectID: String, labelNames: [String]) -> ProjectTemplate? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let template = ProjectTemplate(
            id: UUID().uuidString,
            name: trimmed,
            sectionNames: sections(forProject: projectID).map(\.name),
            labelNames: labelNames,
            createdAt: Date()
        )
        data.templates.append(template)
        persist()
        return template
    }

    /// Applies a template's sections to a project, skipping any that already exist by name so
    /// re-applying is safe rather than duplicating every section.
    func applyTemplate(_ template: ProjectTemplate, toProject projectID: String) {
        let existing = Set(sections(forProject: projectID).map { $0.name.lowercased() })
        for name in template.sectionNames where !existing.contains(name.lowercased()) {
            addSection(name: name, toProject: projectID)
        }
        for labelName in template.labelNames {
            addLabel(name: labelName)
        }
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

    func removeFilter(_ filterID: String) {
        data.filters.removeAll { $0.id == filterID }
        persist()
    }

    // MARK: - Labels

    var labels: [RemitLabel] {
        data.labels.sorted { $0.order < $1.order }
    }

    @discardableResult
    func addLabel(name: String, color: LabelColor = .gray) -> RemitLabel? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = label(named: trimmed) { return existing }

        let label = RemitLabel(
            id: UUID().uuidString,
            name: trimmed,
            color: color,
            order: data.labels.count
        )
        data.labels.append(label)
        persist()
        return label
    }

    /// Case- and space-insensitive, matching how `@my label` is typed in quick add.
    func label(named name: String) -> RemitLabel? {
        let needle = Self.normalize(name)
        return data.labels.first { Self.normalize($0.name) == needle }
    }

    func renameLabel(_ labelID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = data.labels.firstIndex(where: { $0.id == labelID }) else { return }
        data.labels[index].name = trimmed
        persist()
    }

    func setColor(_ color: LabelColor, forLabel labelID: String) {
        guard let index = data.labels.firstIndex(where: { $0.id == labelID }) else { return }
        data.labels[index].color = color
        persist()
    }

    /// Removes the label and every assignment referencing it, so no task is left pointing at an id
    /// that no longer resolves.
    func removeLabel(_ labelID: String) {
        data.labels.removeAll { $0.id == labelID }
        for (taskID, ids) in data.labelAssignments {
            let kept = ids.filter { $0 != labelID }
            data.labelAssignments[taskID] = kept.isEmpty ? nil : kept
        }
        persist()
    }

    func setLabels(_ labelIDs: [String], forTask taskID: String) {
        let valid = Set(data.labels.map(\.id))
        let kept = labelIDs.filter { valid.contains($0) }
        data.labelAssignments[taskID] = kept.isEmpty ? nil : kept
        persist()
    }

    func labels(forTask taskID: String) -> [RemitLabel] {
        let ids = data.labelAssignments[taskID] ?? []
        return ids.compactMap { id in data.labels.first { $0.id == id } }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "")
    }
}
