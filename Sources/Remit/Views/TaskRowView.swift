import SwiftUI

/// Line 1 = title, line 2 = notes at reduced weight, line 3 = date, labels and project -- per
/// prompt #4 in ROADMAP.md, and matching Todoist's own three-line row, where everything secondary
/// shares one line beneath the title instead of crowding it.
///
/// No detail panel opens on click; the mini detail "peek" window from prompt #47 is not yet
/// built.
struct TaskRowView: View {
    let task: RemitTask
    /// Shown on rows in date-based views, where tasks from several projects are mixed together.
    /// Hidden inside a project view, where every row would carry the same dot.
    var showsProject: Bool = false

    @EnvironmentObject private var remindersService: RemindersService
    @EnvironmentObject private var metadataStore: MetadataStore

    /// Drawn by the row rather than left to List's own selection fill: Todoist shows the current
    /// task as an inset rounded card, and a full-bleed grey band reads as a table row instead.
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button {
                toggle()
            } label: {
                Image(systemName: isCompleting || task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(priorityColor)
                    .scaleEffect(isCompleting ? 1.25 : 1)
            }
            .buttonStyle(.plain)
            // Nudged down so the circle centres on the title's cap height rather than its box.
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .strikethrough(isCompleting || task.isCompleted)
                    .font(Theme.taskTitle)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(Theme.taskNotes)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }

                // One metadata line carrying date, labels and project, with the project pushed to
                // the trailing edge. Previously the project sat beside the *title*, which put it in
                // competition with the one thing the row exists to say.
                if hasMetadata {
                    HStack(spacing: 7) {
                        if let badge = TaskGrouping.dueBadge(for: task) {
                            HStack(spacing: 3.5) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 10))
                                Text(badge.label)
                            }
                            .font(Theme.taskMeta)
                            .foregroundStyle(badge.color)
                        }

                        ForEach(labels) { label in
                            LabelChip(label: label)
                        }

                        Spacer(minLength: 8)

                        if showsProject, let project {
                            HStack(spacing: 4) {
                                Text(project.title)
                                    .font(Theme.taskMeta)
                                    .foregroundStyle(Theme.secondaryText)
                                    .lineLimit(1)
                                Circle()
                                    .fill(Color(hex: project.colorHex))
                                    .frame(width: 7, height: 7)
                            }
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Theme.cardBackground : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            isSelected ? Theme.accent.opacity(0.45) : Color.clear,
                            lineWidth: 1
                        )
                )
        )
        .contentShape(Rectangle())
        .opacity(isCompleting ? 0.35 : 1)
        .animation(.easeOut(duration: 0.3), value: isCompleting)
    }

    private var isCompleting: Bool {
        remindersService.completingIDs.contains(task.id)
    }

    /// Whether the metadata line has anything to show, so an empty HStack doesn't add padding.
    private var hasMetadata: Bool {
        TaskGrouping.dueBadge(for: task) != nil
            || !labels.isEmpty
            || (showsProject && project != nil)
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
