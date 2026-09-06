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
                // An empty list with no explanation is a dead end -- filters can only be created
                // from a view's own Display menu, and nothing else on this page says so.
                emptyState(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "No saved filters",
                    body: """
                        A filter is a saved set of view options. Open any view, set the deadline, \
                        priority or label options in the Display menu, then choose Save as Filter. \
                        It appears here and in the sidebar.
                        """
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(metadataStore.filters.enumerated()), id: \.element.id) { index, filter in
                        if index > 0 { Divider().overlay(Theme.separator) }
                        filterRow(filter)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator, lineWidth: 1)
                )
            }
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
            sectionHeader("Labels", count: metadataStore.labels.count)

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
                ForEach(Array(metadataStore.labels.enumerated()), id: \.element.id) { index, label in
                    if index > 0 { Divider().overlay(Theme.separator) }
                    row(label)
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

    private func row(_ label: RemitLabel) -> some View {
        HStack(spacing: 10) {
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
        .contextMenu {
            Button("Show Tasks") { selection = .label(label.id) }
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
