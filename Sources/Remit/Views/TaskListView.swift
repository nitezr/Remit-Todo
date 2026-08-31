import SwiftUI

/// Filters `remindersService.tasks` for the current sidebar selection and renders it as a plain
/// list with quick add and arrow-key navigation.
///
/// The Electron build's Today/Upcoming counts drifted from Reminders.app's own counts twice
/// (ROADMAP.md "Known traps") and its arrow-key navigation skipped items twice. Both live here
/// in one place on purpose: `filteredTasks` is the only date-bucketing logic in the app, and
/// `moveSelection` always walks `filteredTasks` itself rather than a separately-maintained index,
/// so a selection can't point at a row the current filter no longer contains.
struct TaskListView: View {
    let selection: SidebarSelection

    @EnvironmentObject private var remindersService: RemindersService
    @State private var quickAddText = ""
    @FocusState private var quickAddFocused: Bool
    @State private var selectedTaskID: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedTaskID) {
                ForEach(filteredTasks) { task in
                    TaskRowView(task: task)
                        .tag(task.id)
                }
            }
            .listStyle(.plain)
            .onMoveCommand(perform: moveSelection)

            QuickAddView(text: $quickAddText, isFocused: $quickAddFocused, onSubmit: submitQuickAdd)
        }
        .navigationTitle(title)
        .task(id: selection) {
            await remindersService.refreshAll()
        }
    }

    private var filteredTasks: [RemitTask] {
        let openTasks = remindersService.tasks.filter { !$0.isCompleted }
        switch selection {
        case .inbox:
            let defaultID = remindersService.defaultProjectID
            return openTasks.filter { $0.projectID == defaultID }
        case .today:
            return openTasks.filter { $0.isDueToday || $0.isOverdue }
        case .upcoming:
            let startOfToday = Calendar.current.startOfDay(for: Date())
            return openTasks
                .filter { ($0.dueDate ?? .distantPast) >= startOfToday }
                .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        case .project(let id):
            return openTasks.filter { $0.projectID == id }
        }
    }

    private var title: String {
        switch selection {
        case .inbox: return "Inbox"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .project(let id):
            return remindersService.projects.first(where: { $0.id == id })?.title ?? "Project"
        }
    }

    private func submitQuickAdd() {
        let trimmed = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let targetProjectID: String
        if case .project(let id) = selection {
            targetProjectID = id
        } else {
            targetProjectID = remindersService.defaultProjectID ?? remindersService.projects.first?.id ?? ""
        }

        guard !targetProjectID.isEmpty else {
            remindersService.lastError = "No project available to add this task to."
            return
        }

        do {
            try remindersService.createTask(title: trimmed, projectID: targetProjectID)
            quickAddText = ""
            Task { await remindersService.refreshAll() }
        } catch {
            remindersService.lastError = error.localizedDescription
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let tasks = filteredTasks
        guard !tasks.isEmpty else { return }

        guard let currentID = selectedTaskID,
              let currentIndex = tasks.firstIndex(where: { $0.id == currentID }) else {
            selectedTaskID = tasks.first?.id
            return
        }

        switch direction {
        case .down:
            let nextIndex = tasks.index(after: currentIndex)
            if nextIndex < tasks.count {
                selectedTaskID = tasks[nextIndex].id
            }
        case .up:
            if currentIndex > tasks.startIndex {
                let previousIndex = tasks.index(before: currentIndex)
                selectedTaskID = tasks[previousIndex].id
            }
        default:
            break
        }
    }
}
