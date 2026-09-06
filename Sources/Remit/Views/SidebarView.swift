import SwiftUI

/// Sidebar: fixed views, a Favorites section, and the nested project tree with live task counts.
///
/// The Electron build needed ~6 rounds of "still not professional enough" here (ROADMAP.md #13,
/// #22, #40, #43, #45), so spacing, icon weight, and hierarchy are treated as explicit decisions:
/// section headers are small-caps secondary, rows are 13pt, nesting indents by 14pt per level, and
/// counts sit right-aligned in secondary so they never compete with the project name.
struct SidebarView: View {
    @EnvironmentObject private var remindersService: RemindersService
    @EnvironmentObject private var metadataStore: MetadataStore
    @Binding var selection: SidebarSelection?

    @AppStorage("sidebar.favoritesExpanded") private var favoritesExpanded = true
    @AppStorage("sidebar.projectsExpanded") private var projectsExpanded = true
    @State private var emojiTarget: RemitProject?
    @State private var deleteTarget: RemitProject?
    @EnvironmentObject private var uiState: UIState
    @State private var templateSource: RemitProject?
    /// Collapsed parents, persisted as a comma-separated id list. AppStorage can't hold a Set
    /// directly and the list is short, so a joined string beats a second metadata file.
    @AppStorage("sidebar.collapsedProjects") private var collapsedRaw = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                fixedRow(.inbox, title: "Inbox", systemImage: "tray", count: inboxCount)
                fixedRow(.today, title: "Today", systemImage: "calendar", count: todayCount)
                fixedRow(.upcoming, title: "Upcoming", systemImage: "calendar.badge.clock", count: upcomingCount)
                fixedRow(.filtersAndLabels, title: "Filters & Labels", systemImage: "tag", count: nil)
            }

            if !metadataStore.filters.isEmpty {
                Section {
                    ForEach(metadataStore.filters) { filter in
                        HStack(spacing: 6) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundStyle(Theme.secondaryText)
                            Text(filter.name).font(Theme.sidebarRow)
                            Spacer()
                        }
                        .tag(SidebarSelection.filter(filter.id))
                        .contextMenu {
                            Button("Delete Filter", role: .destructive) {
                                metadataStore.removeFilter(filter.id)
                            }
                        }
                    }
                } header: {
                    Text("Filters").font(Theme.sidebarHeader)
                }
            }

            if !favorites.isEmpty {
                Section(isExpanded: $favoritesExpanded) {
                    ForEach(favorites) { project in
                        // Favorites is a flat pinned list, so no disclosure control here even when
                        // the project has children in the tree below.
                        projectRow(project, depth: 0, node: nil)
                    }
                } header: {
                    Text("Favorites").font(Theme.sidebarHeader)
                }
            }

            Section(isExpanded: $projectsExpanded) {
                ForEach(visibleNodes) { node in
                    projectRow(node.project, depth: node.depth, node: node)
                }
                .onMove(perform: moveProjects)
            } header: {
                Text("My Projects").font(Theme.sidebarHeader)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let draggedID = ids.first else { return false }
                        metadataStore.setParent(nil, forProject: draggedID)
                        return true
                    }
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog(
            deleteTarget.map { "Delete \"\($0.title)\"?" } ?? "Delete project?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Project and Tasks", role: .destructive) {
                if let deleteTarget { deleteProject(deleteTarget) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            if let deleteTarget {
                let count = openCount(forProject: deleteTarget.id)
                Text(
                    count == 0
                    ? "This deletes the list from Apple Reminders on all your devices. This cannot be undone."
                    : "This deletes the list and its \(count) task\(count == 1 ? "" : "s") from Apple Reminders on all your devices. This cannot be undone."
                )
            }
        }
        .sheet(item: $templateSource) { project in
            SaveTemplateSheet(project: project) { templateSource = nil }
        }
        .sheet(item: $emojiTarget) { project in
            EmojiPickerSheet(
                projectTitle: project.title,
                current: metadataStore.projectMetadata(project.id).emoji
            ) { emoji in
                metadataStore.setEmoji(emoji, forProject: project.id)
                emojiTarget = nil
            } onCancel: {
                emojiTarget = nil
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    // MARK: - Rows

    private func fixedRow(
        _ target: SidebarSelection,
        title: String,
        systemImage: String,
        count: Int?
    ) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
            Spacer()
            if let count, count > 0 {
                countBadge(count)
            }
        }
        .tag(target)
    }

    private func projectRow(_ project: RemitProject, depth: Int, node: ProjectNode?) -> some View {
        HStack(spacing: 6) {
            // Nesting is drawn with leading padding rather than SwiftUI's DisclosureGroup: a
            // sub-project has to stay individually selectable, and the whole tree is flattened for
            // keyboard navigation anyway.
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 14)
            }

            // A fixed-width slot either way, so names stay aligned whether or not a row has kids.
            Group {
                if let node, !node.children.isEmpty {
                    Button {
                        toggleCollapsed(project.id)
                    } label: {
                        Image(systemName: isCollapsed(project.id) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)

            projectIcon(project)
                .frame(width: 16)
            Text(projectLabel(project))
                .font(Theme.sidebarRow)
                .lineLimit(1)
            Spacer()
            let count = openCount(forProject: project.id)
            if count > 0 {
                countBadge(count)
            }
        }
        .tag(SidebarSelection.project(project.id))
        .contextMenu { projectMenu(project) }
        .draggable(project.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let draggedID = ids.first, draggedID != project.id else { return false }
            // setParent refuses cycles, so dropping a project onto its own descendant is a no-op
            // rather than a detached subtree.
            metadataStore.setParent(project.id, forProject: draggedID)
            return true
        }
    }

    /// Favorites, nesting, and emoji are all Remit-layer metadata with nowhere else to be edited --
    /// without this menu the data model exists but the user can never set any of it.
    @ViewBuilder
    private func projectMenu(_ project: RemitProject) -> some View {
        Button(metadataStore.isFavorite(project.id) ? "Remove from Favorites" : "Add to Favorites") {
            metadataStore.toggleFavorite(project.id)
        }

        Menu("Move to") {
            Button("Top level") {
                metadataStore.setParent(nil, forProject: project.id)
            }
            Divider()
            // Descendants are excluded so a project can't be made a child of its own subtree.
            let blocked = metadataStore.descendantIDs(of: project.id).union([project.id])
            ForEach(listedProjects.filter { !blocked.contains($0.id) }) { candidate in
                Button(candidate.title) {
                    metadataStore.setParent(candidate.id, forProject: project.id)
                }
            }
        }

        Button("Set Emoji...") { emojiTarget = project }
        if metadataStore.projectMetadata(project.id).emoji != nil {
            Button("Remove Emoji") { metadataStore.setEmoji(nil, forProject: project.id) }
        }

        Divider()

        Menu("Template") {
            Button("Save as Template...") { templateSource = project }
            if !metadataStore.templates.isEmpty {
                Divider()
                ForEach(metadataStore.templates) { template in
                    Button("Apply \(template.name)") {
                        metadataStore.applyTemplate(template, toProject: project.id)
                    }
                }
            }
        }

        Divider()

        Button("Delete Project...", role: .destructive) { deleteTarget = project }
    }

    private func deleteProject(_ project: RemitProject) {
        let taskIDs = remindersService.tasks
            .filter { $0.projectID == project.id }
            .map(\.id)
        do {
            try remindersService.deleteProject(project.id)
            metadataStore.forgetProject(project.id, taskIDs: taskIDs)
            // Leaving a deleted project selected would show a permanently empty pane.
            if selection == .project(project.id) { selection = .today }
            Task { await remindersService.refreshAll() }
        } catch {
            remindersService.lastError = error.localizedDescription
        }
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(Theme.taskMeta)
            .foregroundStyle(Theme.secondaryText)
            .monospacedDigit()
    }

    // MARK: - Data

    /// Depth-first, skipping anything under a collapsed parent. Collapsing hides the subtree from
    /// keyboard navigation too, since both walk this same list.
    private var visibleNodes: [ProjectNode] {
        var result: [ProjectNode] = []
        func visit(_ nodes: [ProjectNode]) {
            for node in nodes {
                result.append(node)
                if !isCollapsed(node.project.id) {
                    visit(node.children)
                }
            }
        }
        visit(projectTree)
        return result
    }

    private func isCollapsed(_ projectID: String) -> Bool {
        collapsedRaw.split(separator: ",").contains(Substring(projectID))
    }

    private func toggleCollapsed(_ projectID: String) {
        var ids = Set(collapsedRaw.split(separator: ",").map(String.init))
        if ids.contains(projectID) {
            ids.remove(projectID)
        } else {
            ids.insert(projectID)
        }
        collapsedRaw = ids.sorted().joined(separator: ",")
    }

    /// The default Reminders list is already shown as the fixed "Inbox" row, so it's excluded
    /// here -- otherwise the same list appears twice under two names and clicking either shows
    /// identical tasks.
    private var listedProjects: [RemitProject] {
        let inboxID = remindersService.defaultProjectID
        return remindersService.projects.filter { $0.id != inboxID }
    }

    private var projectTree: [ProjectNode] {
        var parents: [String: String] = [:]
        for (id, meta) in metadataStore.data.projects {
            if let parentID = meta.parentID { parents[id] = parentID }
        }
        return ProjectTree.build(
            projects: listedProjects,
            parents: parents,
            order: metadataStore.projectOrder
        )
    }

    /// Drag-reorder in the sidebar. Dropping next to a project at a different depth also adopts
    /// that project's parent, so one gesture covers both "move above/below" (#58, #60) and
    /// re-nesting -- the Electron build shipped nesting without sibling reordering and it was
    /// reported twice.
    private func moveProjects(from source: IndexSet, to destination: Int) {
        var visible = visibleNodes
        guard let sourceIndex = source.first, sourceIndex < visible.count else { return }
        let moved = visible[sourceIndex]

        // The neighbour the dragged row lands next to decides its new parent.
        let anchorIndex = destination > sourceIndex ? destination - 1 : destination
        let anchor = visible.indices.contains(anchorIndex) ? visible[anchorIndex] : nil
        let newParent = anchor.flatMap { $0.id == moved.id ? nil : parentID(of: $0.id) }

        if newParent != parentID(of: moved.id) {
            metadataStore.setParent(newParent, forProject: moved.id)
        }

        visible.move(fromOffsets: source, toOffset: destination)
        metadataStore.setProjectOrder(visible.map(\.id))
    }

    private func parentID(of projectID: String) -> String? {
        metadataStore.projectMetadata(projectID).parentID
    }

    private var favorites: [RemitProject] {
        let ids = Set(metadataStore.data.favoriteProjectIDs)
        return listedProjects.filter { ids.contains($0.id) }
    }

    /// Most Reminders lists already start with an emoji, so a coloured dot beside it was just
    /// noise. The emoji is the icon; a project without one falls back to a "#" tinted with the
    /// list's colour, which keeps the colour coding without the extra dot.
    @ViewBuilder
    private func projectIcon(_ project: RemitProject) -> some View {
        if let emoji = displayEmoji(project) {
            Text(emoji).font(.system(size: 13))
        } else {
            Text("#")
                .font(Theme.font(13, .semibold))
                .foregroundStyle(Color(hex: project.colorHex))
        }
    }

    /// An explicitly set emoji wins; otherwise a leading emoji in the Reminders list name is used.
    private func displayEmoji(_ project: RemitProject) -> String? {
        if let emoji = metadataStore.projectMetadata(project.id).emoji { return emoji }
        guard let first = project.title.first, first.isEmoji else { return nil }
        return String(first)
    }

    /// The title with its leading emoji removed when that emoji is being drawn as the icon, so it
    /// doesn't appear twice on the row.
    private func projectLabel(_ project: RemitProject) -> String {
        guard metadataStore.projectMetadata(project.id).emoji == nil,
              let first = project.title.first, first.isEmoji else {
            return project.title
        }
        return String(project.title.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Counts come from the same open-task filter the list views use, so a project's badge can't
    /// disagree with the number of rows you see after clicking it.
    private func openCount(forProject id: String) -> Int {
        remindersService.tasks.filter { !$0.isCompleted && $0.projectID == id }.count
    }

    private var inboxCount: Int {
        guard let defaultID = remindersService.defaultProjectID else { return 0 }
        return openCount(forProject: defaultID)
    }

    private var todayCount: Int {
        remindersService.tasks.filter { !$0.isCompleted && ($0.isDueToday || $0.isOverdue) }.count
    }

    /// Mirrors TaskListView's own Upcoming filter exactly -- anything dated today or later, plus
    /// overdue. Deriving it any other way is how the Electron build ended up with a sidebar count
    /// that disagreed with the list it opened (ROADMAP.md "Known traps").
    private var upcomingCount: Int {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return remindersService.tasks.filter { task in
            guard !task.isCompleted else { return false }
            return (task.dueDate ?? .distantPast) >= startOfToday || task.isOverdue
        }.count
    }
}
