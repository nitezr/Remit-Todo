import SwiftUI

/// Line 1 = title, line 2 = notes at reduced weight, no detail panel opens on click -- per
/// prompt #4 in ROADMAP.md. The mini detail "peek" window from prompt #47 is not yet built.
struct TaskRowView: View {
    let task: RemitTask
    @EnvironmentObject private var remindersService: RemindersService

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                toggle()
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(priorityColor)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isCompleted)
                    .font(.system(size: 13))
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let dueDate = task.dueDate {
                Text(dueDate, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(task.isOverdue ? .red : .secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func toggle() {
        do {
            try remindersService.toggleComplete(task)
            Task { await remindersService.refreshAll() }
        } catch {
            remindersService.lastError = error.localizedDescription
        }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .p1: return .red
        case .p2: return .orange
        case .p3: return .blue
        case .p4: return .gray
        }
    }
}
