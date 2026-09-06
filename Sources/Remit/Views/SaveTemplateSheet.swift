import SwiftUI

/// Save a project's structure as a reusable template (#29, #34).
struct SaveTemplateSheet: View {
    let project: RemitProject
    var onDismiss: () -> Void

    @EnvironmentObject private var metadataStore: MetadataStore
    @State private var name = ""
    @State private var includedLabels: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save \(project.title) as Template")
                .font(Theme.font(14, .semibold))

            TextField("Template name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            let sections = metadataStore.sections(forProject: project.id)
            if sections.isEmpty {
                Text("This project has no sections yet. The template will only carry the labels you pick below.")
                    .font(Theme.taskMeta)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sections captured")
                        .font(Theme.taskMeta)
                        .foregroundStyle(Theme.secondaryText)
                    ForEach(sections) { section in
                        Text("• \(section.name)").font(Theme.taskNotes)
                    }
                }
            }

            if !metadataStore.labels.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include labels")
                        .font(Theme.taskMeta)
                        .foregroundStyle(Theme.secondaryText)
                    ForEach(metadataStore.labels) { label in
                        Toggle(isOn: Binding(
                            get: { includedLabels.contains(label.name) },
                            set: { on in
                                if on { includedLabels.insert(label.name) }
                                else { includedLabels.remove(label.name) }
                            }
                        )) {
                            Text(label.name).font(Theme.taskNotes)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            Text("Tasks are never saved into a template — only structure.")
                .font(Theme.taskMeta)
                .foregroundStyle(Theme.secondaryText)

            HStack {
                Spacer()
                Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { name = "\(project.title) template" }
    }

    private func save() {
        metadataStore.saveTemplate(
            name: name,
            fromProject: project.id,
            labelNames: Array(includedLabels)
        )
        onDismiss()
    }
}
