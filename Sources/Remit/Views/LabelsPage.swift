import AppKit
import SwiftUI

/// Saved filters, and the tags in Apple Reminders.
///
/// The tags are Reminders' own: the same set Reminders.app lists under Tags, read from its store
/// and changed through ReminderKit, so renaming one here renames it on every device. There is no
/// "new tag" field because Reminders has no standalone tag -- a tag exists while some reminder
/// carries it -- so tags are made by adding one to a task (`L`, the detail panel, or `@tag` in
/// quick add). Colours and folders went for the same reason: Reminders stores neither, and anything
/// kept only in Remit would stop matching what Reminders shows.
///
/// The Electron build shipped a label section the user could not read (#42), so contrast and
/// sizing are deliberate: 13pt names and hit targets big enough to click.
struct LabelsPage: View {
    @EnvironmentObject private var metadataStore: MetadataStore
    @EnvironmentObject private var remindersService: RemindersService
    @Binding var selection: SidebarSelection?

    @State private var renamingTag: String?
    @State private var draftName = ""
    @State private var removingTag: String?
    @State private var editingFilter: SavedFilter?
    @State private var creatingFilter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                filtersSection
                tagsSection
            }
            .padding(22)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.pageBackground)
        .navigationTitle("Filters & Tags")
        .navigationSubtitle(subtitle)
        .sheet(isPresented: $creatingFilter) {
            FilterEditorSheet(existing: nil) { creatingFilter = false }
        }
        .sheet(item: $editingFilter) { filter in
            FilterEditorSheet(existing: filter) { editingFilter = nil }
        }
        .confirmationDialog(
            removingTag.map { "Remove #\($0) from every task?" } ?? "Remove tag?",
            isPresented: Binding(get: { removingTag != nil }, set: { if !$0 { removingTag = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Tag", role: .destructive) {
                if let removingTag { remindersService.removeTag(removingTag) }
                removingTag = nil
            }
            Button("Cancel", role: .cancel) { removingTag = nil }
        } message: {
            if let removingTag {
                let count = taskCount(removingTag, includingCompleted: true)
                Text("The tag comes off \(count) task\(count == 1 ? "" : "s") in Apple Reminders on all your devices. The tasks themselves are kept.")
            }
        }
    }

    private var subtitle: String {
        let t = remindersService.tags.count
        let f = metadataStore.filters.count
        return "\(f) filter\(f == 1 ? "" : "s") · \(t) tag\(t == 1 ? "" : "s")"
    }

    // MARK: - Filters

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Filters", count: metadataStore.filters.count)

            if metadataStore.filters.isEmpty {
                emptyState(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "No saved filters",
                    body: """
                        A filter is a saved set of criteria — a deadline, a priority, a tag, a \
                        project — that becomes its own view in the sidebar. Create one below, or \
                        save the options you already have set from any view's Display menu.
                        """
                )
            }

            VStack(spacing: 0) {
                ForEach(Array(metadataStore.filters.enumerated()), id: \.element.id) { index, filter in
                    if index > 0 { Divider().overlay(Theme.separator) }
                    filterRow(filter)
                }
                if !metadataStore.filters.isEmpty { Divider().overlay(Theme.separator) }
                // The page is where people look for this; the Display menu route stays, but it is
                // no longer the only one, and it was disabled exactly when you had nothing yet.
                Button { creatingFilter = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 18)
                        Text("New filter")
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator, lineWidth: 1)
            )
        }
    }

    private func filterRow(_ filter: SavedFilter) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(filter.name)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.primaryText)
                // Spelling the criteria out matters: a filter's name says nothing about what it
                // actually selects, and there is no edit screen to go and look.
                Text(summary(filter))
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(filterCount(filter))")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { selection = .filter(filter.id) }
        .contextMenu {
            Button("Show Tasks") { selection = .filter(filter.id) }
            Button("Edit Filter...") { editingFilter = filter }
            Button("Delete Filter", role: .destructive) { metadataStore.removeFilter(filter.id) }
        }
    }

    /// Human-readable criteria, skipping anything left at "all" so the line stays short.
    private func summary(_ filter: SavedFilter) -> String {
        var parts: [String] = []
        if filter.deadline != .all { parts.append(filter.deadline.label) }
        if filter.priority != "all",
           let raw = Int(filter.priority),
           let priority = Priority(rawValue: raw) {
            parts.append(priority.label)
        }
        if filter.labelID != "all" {
            parts.append("#\(filter.labelID)")
        }
        if let projectID = filter.projectID,
           let project = remindersService.projects.first(where: { $0.id == projectID }) {
            parts.append("in \(project.title)")
        }
        return parts.isEmpty ? "Everything" : parts.joined(separator: " · ")
    }

    private func filterCount(_ filter: SavedFilter) -> Int {
        remindersService.tasks.filter { task in
            !task.isCompleted
                && filter.matches(task, labelIDs: task.labels)
        }.count
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Tags", count: remindersService.tags.count)

            switch remindersService.nativeStatus {
            case .needsFullDiskAccess:
                fullDiskAccessState
            case .unavailable(let message):
                emptyState(icon: "exclamationmark.triangle", title: "Tags unavailable", body: message)
            case .unknown, .available:
                if remindersService.tags.isEmpty {
                    emptyState(
                        icon: "number",
                        title: "No tags yet",
                        body: """
                            Tags come from Apple Reminders. Add one to a task with the L key, from its \
                            detail panel, or by typing @tag in quick add, and it appears here and in \
                            Reminders.app.
                            """
                    )
                } else {
                    tagList
                }
            }
        }
    }

    private var tagList: some View {
        VStack(spacing: 0) {
            ForEach(Array(remindersService.tags.enumerated()), id: \.element.id) { index, tag in
                if index > 0 { Divider().overlay(Theme.separator) }
                row(tag)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator, lineWidth: 1)
        )
    }

    private var fullDiskAccessState: some View {
        VStack(alignment: .leading, spacing: 10) {
            emptyState(
                icon: "lock",
                title: "Remit can't read your Reminders tags yet",
                body: """
                    Tags and sections are read straight from Apple Reminders' own database, which \
                    macOS protects. Add Remit under Privacy & Security › Full Disk Access, then quit \
                    and reopen Remit.
                    """
            )
            Button("Open Privacy & Security") {
                NSWorkspace.shared.open(NativeMetadataStatus.fullDiskAccessSettingsURL)
            }
        }
    }

    private func row(_ tag: ReminderTag) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "number")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18)

            if renamingTag == tag.name {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Theme.font(13))
                    .onSubmit { commitRename(tag) }
                    .onExitCommand { renamingTag = nil }
            } else {
                Text(tag.name)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text("\(taskCount(tag.name))")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { selection = .label(tag.name) }
        .contextMenu {
            Button("Show Tasks") { selection = .label(tag.name) }
            Button("Rename…") {
                draftName = tag.name
                renamingTag = tag.name
            }
            Button("Remove from All Tasks…", role: .destructive) { removingTag = tag.name }
        }
    }

    // MARK: - Chrome

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(Theme.font(15, .semibold))
                .foregroundStyle(Theme.primaryText)
            Text("\(count)")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
            Spacer()
        }
    }

    private func emptyState(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(body)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.columnBackground))
    }

    private func taskCount(_ name: String, includingCompleted: Bool = false) -> Int {
        remindersService.tasks.filter { task in
            (includingCompleted || !task.isCompleted) && task.labels.contains(name)
        }.count
    }

    private func commitRename(_ tag: ReminderTag) {
        remindersService.renameTag(tag.name, to: draftName)
        renamingTag = nil
    }
}
