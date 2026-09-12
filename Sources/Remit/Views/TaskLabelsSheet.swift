import SwiftUI

/// Tag one task. Opened with `l`, matching the Glaze build's `addLabels` shortcut. The tags are
/// Apple Reminders' own, so a change here is the same change in Reminders.app.
struct TaskLabelsSheet: View {
    let task: RemitTask
    var onDismiss: () -> Void

    @EnvironmentObject private var remindersService: RemindersService
    @State private var newTagName = ""

    private var assigned: [String] {
        remindersService.current(task).labels
    }

    /// Every Reminders tag, plus any this task carries that the last read hasn't caught up with --
    /// a tag typed a moment ago is on the task before it is in the store's list.
    private var allTags: [String] {
        var names = remindersService.tags.map(\.name)
        for name in assigned where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags for \(task.title)")
                .font(Theme.font(13, .semibold))
                .lineLimit(2)

            if remindersService.nativeStatus == .needsFullDiskAccess {
                Text("Remit needs Full Disk Access to read your Reminders tags before it can change them.")
                    .font(Theme.font(11))
                    .foregroundStyle(.secondary)
            } else if allTags.isEmpty {
                Text("No tags yet. Type below to add one.")
                    .font(Theme.font(11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(allTags, id: \.self) { name in
                            Toggle(isOn: binding(for: name)) {
                                HStack(spacing: 5) {
                                    Image(systemName: "number")
                                        .font(.system(size: 9))
                                        .foregroundStyle(ReminderTag.chipColor)
                                    Text(name).font(Theme.font(12))
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            HStack(spacing: 6) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("New tag", text: $newTagName)
                    .textFieldStyle(.plain)
                    .onSubmit(createAndAssign)
            }

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { assigned.contains(name) },
            set: { isOn in
                var names = assigned
                if isOn {
                    if !names.contains(name) { names.append(name) }
                } else {
                    names.removeAll { $0 == name }
                }
                remindersService.setTags(names, for: task)
            }
        )
    }

    private func createAndAssign() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        remindersService.setTags(assigned + [name], for: task)
        newTagName = ""
    }
}
