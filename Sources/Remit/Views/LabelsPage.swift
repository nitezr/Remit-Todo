import SwiftUI

/// Manage Remit's filters and labels.
///
/// Labels are entirely Remit's own. ROADMAP.md #27 assumed they would map to Apple Reminders'
/// native tags; #32 said to check that against real data before assuming a schema, and the check
/// settles it -- **EventKit exposes no tags API at all**, on `EKReminder` or `EKCalendarItem`, so
/// Reminders tags cannot be read or written through the public framework. A Remit-side layer is
/// not a shortcut here, it is the only option, which is why this page is where labels come from.
///
/// The Electron build shipped a label section the user could not read (#42), so contrast and
/// sizing are deliberate: 13pt names, full-strength swatches, and hit targets big enough to click.
struct LabelsPage: View {
    @EnvironmentObject private var metadataStore: MetadataStore
    @EnvironmentObject private var remindersService: RemindersService
    @Binding var selection: SidebarSelection?

    @State private var newLabelName = ""
    @State private var renamingID: String?
    @State private var draftName = ""
    @State private var editingFilter: SavedFilter?
    @State private var creatingFilter = false
    @State private var newFolderName = ""
    @State private var addingFolder = false
    /// Collapsed folder ids, comma-joined -- AppStorage cannot hold a Set and the list is short.
    @AppStorage("labels.collapsedFolders") private var collapsedFolders = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                filtersSection
                labelsSection
            }
            .padding(22)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.pageBackground)
        .navigationTitle("Filters & Labels")
        .navigationSubtitle(subtitle)
        .sheet(isPresented: $creatingFilter) {
            FilterEditorSheet(existing: nil) { creatingFilter = false }
        }
        .sheet(item: $editingFilter) { filter in
            FilterEditorSheet(existing: filter) { editingFilter = nil }
        }
    }

    private var subtitle: String {
        let l = metadataStore.labels.count
        let f = metadataStore.filters.count
        return "\(f) filter\(f == 1 ? "" : "s") · \(l) label\(l == 1 ? "" : "s")"
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
                        A filter is a saved set of criteria — a deadline, a priority, a label, a \
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
                .font(Theme.font(11.5))
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
        if filter.labelID != "all",
           let label = metadataStore.labels.first(where: { $0.id == filter.labelID }) {
            parts.append("@\(label.name)")
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
                && filter.matches(task, labelIDs: metadataStore.labels(forTask: task.id).map(\.id))
        }.count
    }

    // MARK: - Labels

    private var labelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("Labels")
                    .font(Theme.font(15, .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("\(metadataStore.labels.count)")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
                Spacer()
                Button { addingFolder = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 11))
                        Text("New folder").font(Theme.font(12))
                    }
                    .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }

            if metadataStore.labels.isEmpty {
                emptyState(
                    icon: "tag",
                    title: "No labels yet",
                    body: """
                        Labels live in Remit rather than in Apple Reminders: EventKit exposes no \
                        API for Reminders tags, so they cannot be read from or written back to it. \
                        Create one below, then add it to a task with the L key or from the task's \
                        detail panel.
                        """
                )
            }

            VStack(spacing: 0) {
                if addingFolder { newFolderRow }

                ForEach(metadataStore.labelFolders) { folder in
                    folderHeader(folder)
                    if !isCollapsed(folder.id) {
                        ForEach(metadataStore.labels(inFolder: folder.id)) { label in
                            Divider().overlay(Theme.separator)
                            row(label, indented: true)
                        }
                    }
                    Divider().overlay(Theme.separator)
                }

                // Unfiled labels. Given a header only when folders exist, so it has somewhere to
                // drag *out* to -- without it a label put in a folder could never leave.
                if !metadataStore.labelFolders.isEmpty && !metadataStore.labels(inFolder: nil).isEmpty {
                    unfiledHeader
                    Divider().overlay(Theme.separator)
                }
                ForEach(Array(metadataStore.labels(inFolder: nil).enumerated()), id: \.element.id) { index, label in
                    if index > 0 { Divider().overlay(Theme.separator) }
                    row(label, indented: false)
                }

                if !metadataStore.labels.isEmpty { Divider().overlay(Theme.separator) }
                newLabelRow
            }
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator, lineWidth: 1)
            )
        }
    }

    private func folderHeader(_ folder: LabelFolder) -> some View {
        HStack(spacing: 8) {
            Button { toggleCollapsed(folder.id) } label: {
                Image(systemName: isCollapsed(folder.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)

            if renamingID == folder.id {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Theme.font(13, .semibold))
                    .onSubmit {
                        metadataStore.renameLabelFolder(folder.id, to: draftName)
                        renamingID = nil
                    }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(folder.name)
                    .font(Theme.font(13, .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text("\(metadataStore.labels(inFolder: folder.id).count)")
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.columnBackground)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            metadataStore.setFolder(folder.id, forLabel: id)
            return true
        }
        .contextMenu {
            Button("Rename Folder") {
                draftName = folder.name
                renamingID = folder.id
            }
            Button("Move Up") { metadataStore.moveLabelFolder(folder.id, by: -1) }
            Button("Move Down") { metadataStore.moveLabelFolder(folder.id, by: 1) }
            // Labels survive their folder; only the grouping goes.
            Button("Delete Folder", role: .destructive) {
                metadataStore.removeLabelFolder(folder.id)
            }
        }
    }

    private var unfiledHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Text("Unfiled")
                .font(Theme.font(12, .semibold))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.columnBackground)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            metadataStore.setFolder(nil, forLabel: id)
            return true
        }
    }

    private var newFolderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18)
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .onSubmit(createFolder)
                .onExitCommand { addingFolder = false; newFolderName = "" }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            addingFolder = false
            return
        }
        metadataStore.addLabelFolder(name: name)
        newFolderName = ""
        addingFolder = false
    }

    private func isCollapsed(_ id: String) -> Bool {
        collapsedFolders.split(separator: ",").contains(Substring(id))
    }

    private func toggleCollapsed(_ id: String) {
        var ids = collapsedFolders.split(separator: ",").map(String.init)
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        collapsedFolders = ids.joined(separator: ",")
    }

    private var newLabelRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18)
            TextField("New label", text: $newLabelName)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .onSubmit(createLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func row(_ label: RemitLabel, indented: Bool) -> some View {
        HStack(spacing: 10) {
            if indented { Spacer().frame(width: 18) }
            Menu {
                ForEach(LabelColor.allCases, id: \.self) { color in
                    Button {
                        metadataStore.setColor(color, forLabel: label.id)
                    } label: {
                        Label(color.rawValue.capitalized, systemImage: "circle.fill")
                    }
                }
            } label: {
                Circle()
                    .fill(label.color.swiftUIColor)
                    .frame(width: 12, height: 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)

            if renamingID == label.id {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Theme.font(13))
                    .onSubmit { commitRename(label) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(label.name)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text("\(taskCount(label))")
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { selection = .label(label.id) }
        .draggable(label.id)
        // Dropping one label on another reorders within, or moves into, that label's folder.
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            metadataStore.moveLabel(id, after: label.id)
            return true
        }
        .contextMenu {
            Button("Show Tasks") { selection = .label(label.id) }
            if !metadataStore.labelFolders.isEmpty {
                Menu("Move to Folder") {
                    Button("Unfiled") { metadataStore.setFolder(nil, forLabel: label.id) }
                    ForEach(metadataStore.labelFolders) { folder in
                        Button(folder.name) { metadataStore.setFolder(folder.id, forLabel: label.id) }
                    }
                }
            }
            Button("Rename") {
                draftName = label.name
                renamingID = label.id
            }
            // Deleting a label only removes the label; the tasks carrying it are untouched.
            Button("Delete Label", role: .destructive) {
                metadataStore.removeLabel(label.id)
            }
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
                    .font(Theme.font(12.5, .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(body)
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.columnBackground))
    }

    private func taskCount(_ label: RemitLabel) -> Int {
        remindersService.tasks.filter { task in
            !task.isCompleted && metadataStore.labels(forTask: task.id).contains { $0.id == label.id }
        }.count
    }

    private func createLabel() {
        let name = newLabelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        metadataStore.addLabel(name: name)
        newLabelName = ""
    }

    private func commitRename(_ label: RemitLabel) {
        metadataStore.renameLabel(label.id, to: draftName)
        renamingID = nil
    }
}
