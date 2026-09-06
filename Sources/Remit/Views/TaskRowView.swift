import SwiftUI

/// Line 1 = title, line 2 = notes at reduced weight, then label chips -- per prompt #4 in
/// ROADMAP.md. No detail panel opens on click; the mini detail "peek" window from prompt #47 is
/// not yet built.
struct TaskRowView: View {
    let task: RemitTask
    /// Shown on rows in date-based views, where tasks from several projects are mixed together.
    /// Hidden inside a project view, where every row would carry the same dot.
    var showsProject: Bool = false

    @EnvironmentObject private var remindersService: RemindersService
    @EnvironmentObject private var metadataStore: MetadataStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                toggle()
            } label: {
                Image(systemName: isCompleting || task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(priorityColor)
                    .scaleEffect(isCompleting ? 1.25 : 1)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(isCompleting || task.isCompleted)
                    .font(Theme.taskTitle)
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(Theme.taskNotes)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                if !metadata.isEmpty {
                    HStack(spacing: 6) {
                        if let badge = TaskGrouping.dueBadge(for: task) {
                            HStack(spacing: 3) {
                                Image(systemName: "calendar")
                                Text(badge.label)
                            }
                            .font(Theme.taskMeta)
                            .foregroundStyle(badge.color)
                        }
                        ForEach(labels) { label in
                            LabelChip(label: label)
                        }
                    }
                }
            }

            Spacer()

            if showsProject, let project = project {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(hex: project.colorHex))
                        .frame(width: 7, height: 7)
                    Text(project.title)
                        .font(Theme.taskMeta)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(isCompleting ? 0.35 : 1)
        .animation(.easeOut(duration: 0.3), value: isCompleting)
    }

    private var isCompleting: Bool {
        remindersService.completingIDs.contains(task.id)
    }

    /// Whether the metadata line has anything to show, so an empty HStack doesn't add padding.
    private var metadata: [String] {
        var parts: [String] = []
        if TaskGrouping.dueBadge(for: task) != nil { parts.append("due") }
        if !labels.isEmpty { parts.append("labels") }
        return parts
    }

    private var labels: [RemitLabel] {
        metadataStore.labels(forTask: task.id)
    }

    private var project: RemitProject? {
        remindersService.projects.first { $0.id == task.projectID }
    }

    private func toggle() {
        remindersService.completeAnimated(task)
    }

    private var priorityColor: Color { Theme.priority(task.priority) }
}

/// Todoist-style label pill. Deliberately low-contrast against the title so a task with several
/// labels still reads title-first -- the Electron build shipped a label UI that was unreadable
/// (ROADMAP.md #42), so contrast here is a requirement rather than a detail.
struct LabelChip: View {
    let label: RemitLabel

    var body: some View {
        Text(label.name)
            .font(Theme.taskMeta)
            .foregroundStyle(label.color.swiftUIColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(label.color.swiftUIColor.opacity(0.15))
            )
    }
}
