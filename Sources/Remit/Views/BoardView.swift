import SwiftUI

/// Kanban layout: one column per section, cards inside.
///
/// The Electron build had a real bug here -- moving a task from Tomorrow to Today made it vanish
/// instead of appearing in the Today column, because the board's date buckets were only recomputed
/// on reload (ROADMAP.md #7). This view holds no bucket state of its own: `columns` is derived from
/// the same `TaskGrouping.Section` list the List layout uses, so a move that changes a task's date
/// or section is reflected on the next render with nothing to invalidate.
struct BoardView: View {
    let sections: [TaskGrouping.Section]
    let showsProject: Bool
    /// Board has no List to draw selection for it, so the selected card is highlighted here --
    /// otherwise j/k/e/t all fire correctly but appear to do nothing.
    @Binding var selectedTaskID: String?
    /// Nil in views where sections aren't a concept (Today, Upcoming), which hides the add column.
    var onAddSection: ((String) -> Void)?
    var onDrop: (RemitTask, TaskGrouping.Section) -> Void

    @State private var newSectionName = ""
    @State private var addingSection = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(sections) { section in
                    column(section)
                }
                if onAddSection != nil {
                    addSectionColumn
                }
            }
            .padding(12)
        }
    }

    /// Board needs its own section-creation affordance -- the List layout's "Add section" row
    /// isn't reachable from here.
    @ViewBuilder
    private var addSectionColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if addingSection {
                TextField("Section name", text: $newSectionName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let name = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { onAddSection?(name) }
                        newSectionName = ""
                        addingSection = false
                    }
                    .onExitCommand {
                        newSectionName = ""
                        addingSection = false
                    }
            } else {
                Button {
                    addingSection = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Add section")
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 220)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    private func column(_ section: TaskGrouping.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.title)
                    .font(Theme.sectionHeader)
                Spacer()
                Text("\(section.tasks.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 2)

            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(section.tasks) { task in
                        TaskCard(
                            task: task,
                            showsProject: showsProject,
                            isSelected: task.id == selectedTaskID
                        )
                        .id(task.id)
                        .draggable(task.id)
                        .onTapGesture { selectedTaskID = task.id }
                    }
                }
              }
              // Keyboard navigation can move the selection into a column that's scrolled out of
              // view; follow it so j/k don't select something invisible.
              .onChange(of: selectedTaskID) {
                  guard let selectedTaskID,
                        section.tasks.contains(where: { $0.id == selectedTaskID }) else { return }
                  withAnimation { proxy.scrollTo(selectedTaskID, anchor: .center) }
              }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 260)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.columnBackground)
        )
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first,
                  let task = sections.flatMap(\.tasks).first(where: { $0.id == id }) else { return false }
            onDrop(task, section)
            return true
        }
    }
}

/// Board card. Kept visually distinct from a list row: bordered, padded, and metadata stacked
/// underneath rather than trailing, matching the reference screenshots (ROADMAP.md #14, #23).
struct TaskCard: View {
    let task: RemitTask
    var showsProject: Bool
    var isSelected: Bool = false

    @EnvironmentObject private var remindersService: RemindersService
    @EnvironmentObject private var metadataStore: MetadataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    toggle()
                } label: {
                    Image(systemName: isCompleting || task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(priorityColor)
                        .scaleEffect(isCompleting ? 1.25 : 1)
                }
                .buttonStyle(.plain)

                Text(task.title)
                    .font(Theme.cardTitle)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }

            if let notes = task.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                if let badge = TaskGrouping.dueBadge(for: task) {
                    Text(badge.label)
                        .font(.system(size: 10))
                        .foregroundStyle(badge.color)
                }
                ForEach(metadataStore.labels(forTask: task.id)) { label in
                    LabelChip(label: label)
                }
                Spacer(minLength: 0)
                if showsProject, let project = project {
                    Circle()
                        .fill(Color(hex: project.colorHex))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSelected ? Theme.accent : Theme.separator,
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .opacity(isCompleting ? 0.35 : 1)
        .animation(.easeOut(duration: 0.3), value: isCompleting)
    }

    private var project: RemitProject? {
        remindersService.projects.first { $0.id == task.projectID }
    }

    private var isCompleting: Bool {
        remindersService.completingIDs.contains(task.id)
    }

    private func toggle() {
        remindersService.completeAnimated(task)
    }

    private var priorityColor: Color { Theme.priority(task.priority) }
}
