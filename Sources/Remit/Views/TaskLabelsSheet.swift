import SwiftUI

/// Assign labels to one task. Opened with `l`, matching the Glaze build's `addLabels` shortcut.
struct TaskLabelsSheet: View {
    let task: RemitTask
    var onDismiss: () -> Void

    @EnvironmentObject private var metadataStore: MetadataStore
    @State private var newLabelName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Labels for \(task.title)")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)

            if metadataStore.labels.isEmpty {
                Text("No labels yet. Type below to create one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(metadataStore.labels) { label in
                            Toggle(isOn: binding(for: label)) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(label.color.swiftUIColor)
                                        .frame(width: 9, height: 9)
                                    Text(label.name).font(.system(size: 12))
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
                TextField("New label", text: $newLabelName)
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

    private func binding(for label: RemitLabel) -> Binding<Bool> {
        Binding(
            get: { metadataStore.labels(forTask: task.id).contains { $0.id == label.id } },
            set: { isOn in
                var ids = metadataStore.labels(forTask: task.id).map(\.id)
                if isOn {
                    if !ids.contains(label.id) { ids.append(label.id) }
                } else {
                    ids.removeAll { $0 == label.id }
                }
                metadataStore.setLabels(ids, forTask: task.id)
            }
        )
    }

    private func createAndAssign() {
        let name = newLabelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let created = metadataStore.addLabel(name: name) else { return }
        var ids = metadataStore.labels(forTask: task.id).map(\.id)
        ids.append(created.id)
        metadataStore.setLabels(ids, forTask: task.id)
        newLabelName = ""
    }
}
