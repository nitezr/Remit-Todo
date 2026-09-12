import SwiftUI

/// Sidebar: fixed views, a Favorites section, and the project list with live task counts, grouped
/// the way Reminders groups it.
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
    /// Collapsed groups, persisted as a comma-separated id list. AppStorage can't hold a Set
    /// directly and the list is short, so a joined string beats a second metadata file.
    @AppStorage("sidebar.collapsedProjects") private var collapsedRaw = ""

    var body: some View {
        Group {
            if DemoMode.flattensSidebar {
                snapshotSidebar
            } else {
                sidebarList
            }
        }
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
        // Pinned beneath the list rather than placed inside it. A footer that scrolls away is a
        // footer nobody finds, and #35 was a real bug where a sticky panel ate the project list's
        // scroll space -- safeAreaInset reserves its own room instead of overlapping.
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            Section {
                fixedRow(.inbox, title: "Inbox", systemImage: "tray", count: inboxCount)
                fixedRow(.today, title: "Today", systemImage: "calendar", count: todayCount)
                fixedRow(.upcoming, title: "Upcoming", systemImage: "calendar.badge.clock", count: upcomingCount)
                fixedRow(.filtersAndLabels, title: "Filters & Tags", systemImage: "number", count: nil)
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
                        projectRow(project, depth: 0)
                    }
                } header: {
                    Text("Favorites").font(Theme.sidebarHeader)
                }
            }

            Section(isExpanded: $projectsExpanded) {
                ForEach(projectRows) { row in
                    switch row.kind {
                    case .group(let group):
                        groupRow(group)
                    case .project(let project, let depth):
                        projectRow(project, depth: depth)
                    }
                }
                .onMove(perform: moveProjects)
            } header: {
                // Dropping a list on the header takes it out of its Reminders group.
                Text("My Projects").font(Theme.sidebarHeader)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let draggedID = ids.first else { return false }
                        remindersService.setGroup(nil, forProject: draggedID)
                        return true
                    }
            }
        }
        .listStyle(.sidebar)
    }

    /// Demo screenshots only: the same rows, stacked without a List. A List's rows never draw into
    /// a window's cached image -- all of them were present, visible and full size, and the sidebar
    /// still came out blank -- and a cached image is the only screenshot an app can take of itself
    /// without screen-recording permission.
    private var snapshotSidebar: some View {
        // No ScrollView either: its content sits in a nested view that also stayed blank. The rows
        // fit a screenshot-sized window, so a plain stack is enough.
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                snapshotRow(.inbox) { fixedRow(.inbox, title: "Inbox", systemImage: "tray", count: inboxCount) }
                snapshotRow(.today) { fixedRow(.today, title: "Today", systemImage: "calendar", count: todayCount) }
                snapshotRow(.upcoming) {
                    fixedRow(.upcoming, title: "Upcoming", systemImage: "calendar.badge.clock", count: upcomingCount)
                }
                snapshotRow(.filtersAndLabels) {
                    fixedRow(.filtersAndLabels, title: "Filters & Tags", systemImage: "number", count: nil)
                }

                if !metadataStore.filters.isEmpty {
                    snapshotHeader("Filters")
                    ForEach(metadataStore.filters) { filter in
                        snapshotRow(.filter(filter.id)) {
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .foregroundStyle(Theme.secondaryText)
                                Text(filter.name).font(Theme.sidebarRow)
                                Spacer()
                            }
                        }
                    }
                }

                if !favorites.isEmpty {
                    snapshotHeader("Favorites")
                    ForEach(favorites) { project in
                        snapshotRow(.project(project.id)) { projectRow(project, depth: 0) }
                    }
                }

                snapshotHeader("My Projects")
                ForEach(projectRows) { row in
                    switch row.kind {
                    case .group(let group):
                        groupRow(group)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    case .project(let project, let depth):
                        snapshotRow(.project(project.id)) { projectRow(project, depth: depth) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private func snapshotHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.sidebarHeader)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func snapshotRow<Content: View>(
        _ target: SidebarSelection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            // A List gives each row its height; in a stack, the rows' fixed-width spacers would
            // otherwise stretch to share the window's spare height.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selection == target ? Theme.accent.opacity(0.14) : Color.clear)
            )
    }

    // MARK: - Footer

    /// Help and Settings, always reachable from the sidebar itself (#38 asked for the gear here,
    /// icon-only). Kept deliberately quiet: two permanent controls sitting under the project tree
    /// should recede until pointed at, which is why there is no framed box around them -- a border
    /// at this size reads as a stuck button rather than a resting control.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.separator)
            HStack(spacing: 4) {
                SidebarFooterButton(
                    systemImage: "questionmark.circle",
                    label: "Keyboard Shortcuts",
                    help: "Keyboard shortcuts (?)"
                ) { uiState.shortcutsHelpOpen = true }

                Spacer(minLength: 0)

                SidebarFooterButton(
                    systemImage: "gearshape",
                    label: nil,
                    help: "Settings (⌘,)"
                ) { uiState.settingsOpen = true }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Theme.sidebarBackground)
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

    /// A Reminders group. Not selectable -- a group holds lists, not tasks -- so a click folds it.
    private func groupRow(_ group: ListGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed(group.id) ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 16)
            Text(group.name)
                .font(Theme.sidebarRow)
                .lineLimit(1)
            Spacer()
            let count = group.projectIDs.reduce(0) { $0 + openCount(forProject: $1) }
            if count > 0 {
                countBadge(count)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleCollapsed(group.id) }
        .moveDisabled(true)
        .dropDestination(for: String.self) { ids, _ in
            guard let draggedID = ids.first else { return false }
            remindersService.setGroup(group.id, forProject: draggedID)
            return true
        }
    }

    private func projectRow(_ project: RemitProject, depth: Int) -> some View {
        HStack(spacing: 6) {
            // Lists inside a group are indented by padding rather than a DisclosureGroup, so each
            // stays individually selectable and the rows flatten for keyboard navigation.
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 14)
            }
            // Keeps names aligned with group rows, whose chevron sits in this slot.
            Color.clear.frame(width: 10)

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
        // Dropping one list on another puts it in the same Reminders group.
        .dropDestination(for: String.self) { ids, _ in
            guard let draggedID = ids.first, draggedID != project.id else { return false }
            remindersService.setGroup(project.groupID, forProject: draggedID)
            return true
        }
    }

    /// Favorites and emoji are Remit-layer metadata with nowhere else to be edited; the group is
    /// Reminders' own and changes there too.
    @ViewBuilder
    private func projectMenu(_ project: RemitProject) -> some View {
        Button(metadataStore.isFavorite(project.id) ? "Remove from Favorites" : "Add to Favorites") {
            metadataStore.toggleFavorite(project.id)
        }

        if !remindersService.groups.isEmpty {
            Menu("Move to Group") {
                Button("No Group" + (project.groupID == nil ? " ✓" : "")) {
                    remindersService.setGroup(nil, forProject: project.id)
                }
                Divider()
                ForEach(remindersService.groups) { group in
                    Button(group.name + (project.groupID == group.id ? " ✓" : "")) {
                        remindersService.setGroup(group.id, forProject: project.id)
                    }
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
                        apply(template, to: project)
                    }
                }
            }
        }

        Divider()

        Button("Delete Project...", role: .destructive) { deleteTarget = project }
    }

    /// Creates the template's sections in Reminders, skipping names the list already has so
    /// applying twice never duplicates a section.
    private func apply(_ template: ProjectTemplate, to project: RemitProject) {
        let existing = Set(remindersService.sections(forProject: project.id).map { $0.name.lowercased() })
        remindersService.createSections(
            named: template.sectionNames.filter { !existing.contains($0.lowercased()) },
            inProject: project.id
        )
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

    private struct SidebarRow: Identifiable {
        enum Kind {
            case group(ListGroup)
            case project(RemitProject, depth: Int)
        }

        let kind: Kind

        var id: String {
            switch kind {
            case .group(let group): return "group:\(group.id)"
            case .project(let project, _): return project.id
            }
        }
    }

    /// Each Reminders group with its lists beneath it, then the lists in no group. Lists inside a
    /// collapsed group are left out, which takes them out of keyboard navigation too.
    private var projectRows: [SidebarRow] {
        let ordered = sortedByProjectOrder(listedProjects)
        let groupIDs = Set(remindersService.groups.map(\.id))
        var rows: [SidebarRow] = []
        for group in remindersService.groups {
            rows.append(SidebarRow(kind: .group(group)))
            guard !isCollapsed(group.id) else { continue }
            rows += ordered
                .filter { $0.groupID == group.id }
                .map { SidebarRow(kind: .project($0, depth: 1)) }
        }
        rows += ordered
            .filter { $0.groupID.map { !groupIDs.contains($0) } ?? true }
            .map { SidebarRow(kind: .project($0, depth: 0)) }
        return rows
    }

    /// Remit's saved order first, then anything never ordered in the order Reminders returned it.
    private func sortedByProjectOrder(_ projects: [RemitProject]) -> [RemitProject] {
        let position = Dictionary(
            metadataStore.projectOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return projects.enumerated().sorted { lhs, rhs in
            switch (position[lhs.element.id], position[rhs.element.id]) {
            case let (left?, right?): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }

    private func isCollapsed(_ groupID: String) -> Bool {
        collapsedRaw.split(separator: ",").contains(Substring(groupID))
    }

    private func toggleCollapsed(_ groupID: String) {
        var ids = Set(collapsedRaw.split(separator: ",").map(String.init))
        if ids.contains(groupID) {
            ids.remove(groupID)
        } else {
            ids.insert(groupID)
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

    /// Drag-reorder. The order is Remit's own, so this only reorders. Changing a list's group is
    /// a drop onto the group or "Move to Group", because that one writes to Reminders.
    private func moveProjects(from source: IndexSet, to destination: Int) {
        var rows = projectRows
        rows.move(fromOffsets: source, toOffset: destination)
        let ids = rows.compactMap { row -> String? in
            if case .project(let project, _) = row.kind { return project.id }
            return nil
        }
        metadataStore.setProjectOrder(ids)
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

/// A sidebar footer control: quiet until hovered, then a soft rounded highlight -- the same
/// treatment the rows above it get on selection, so the footer belongs to the sidebar rather than
/// looking bolted beneath it.
private struct SidebarFooterButton: View {
    let systemImage: String
    /// `nil` renders icon-only, which is what #38 asked for on the settings gear.
    let label: String?
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                if let label {
                    Text(label)
                        .font(Theme.font(13))
                }
            }
            .foregroundStyle(hovering ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Theme.separator : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
