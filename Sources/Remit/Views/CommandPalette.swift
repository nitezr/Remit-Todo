import SwiftUI

/// ⌘K: search every task and run app actions from one surface (ROADMAP.md #19).
///
/// Search is also reachable here rather than only behind its own shortcut (#67) -- typing plain
/// text searches tasks, and actions surface alongside so "today" finds both the Today view and
/// tasks with "today" in the title.
struct CommandPalette: View {
    let tasks: [RemitTask]
    let projects: [RemitProject]
    var onSelectTask: (RemitTask) -> Void
    var onSelectView: (SidebarSelection) -> Void
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search tasks or jump to a view", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit(runHighlighted)
                    .onChange(of: query) { highlighted = 0 }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        resultRow(result, isHighlighted: index == highlighted)
                            .onTapGesture { run(result) }
                    }
                    if results.isEmpty {
                        Text("No matches")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 520)
        .onAppear { fieldFocused = true }
        .onExitCommand(perform: onDismiss)
        // Arrow keys move the highlight; the field keeps focus so typing continues to work.
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlighted = min(max(0, results.count - 1), highlighted + 1)
            return .handled
        }
    }

    private func resultRow(_ result: Result, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let subtitle = result.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Results

    private struct Result: Identifiable {
        let id: String
        let title: String
        var subtitle: String?
        let systemImage: String
        let action: Action

        enum Action {
            case task(RemitTask)
            case view(SidebarSelection)
        }
    }

    /// Views first when the query is short, tasks after -- with an empty query the palette is a
    /// jump list rather than a dump of every task.
    private var results: [Result] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var views: [Result] = [
            Result(id: "view.today", title: "Today", systemImage: "calendar", action: .view(.today)),
            Result(id: "view.upcoming", title: "Upcoming", systemImage: "calendar.badge.clock", action: .view(.upcoming)),
            Result(id: "view.inbox", title: "Inbox", systemImage: "tray", action: .view(.inbox)),
            Result(id: "view.labels", title: "Filters & Labels", systemImage: "tag", action: .view(.filtersAndLabels)),
        ]
        views += projects.map {
            Result(id: "view.\($0.id)", title: $0.title, subtitle: "Project", systemImage: "circle.fill", action: .view(.project($0.id)))
        }

        guard !needle.isEmpty else { return views }

        let matchedViews = views.filter { $0.title.lowercased().contains(needle) }
        let matchedTasks = tasks
            .filter { !$0.isCompleted && $0.title.lowercased().contains(needle) }
            .prefix(40)
            .map { task in
                Result(
                    id: "task.\(task.id)",
                    title: task.title,
                    subtitle: projects.first { $0.id == task.projectID }?.title,
                    systemImage: "circle",
                    action: .task(task)
                )
            }
        return matchedViews + matchedTasks
    }

    private func runHighlighted() {
        guard highlighted < results.count else { return }
        run(results[highlighted])
    }

    private func run(_ result: Result) {
        switch result.action {
        case .task(let task): onSelectTask(task)
        case .view(let selection): onSelectView(selection)
        }
        onDismiss()
    }
}
