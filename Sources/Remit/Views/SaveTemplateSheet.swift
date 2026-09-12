import SwiftUI

/// Save a project's structure as a reusable template (#29, #34).
struct SaveTemplateSheet: View {
    let project: RemitProject
    var onDismiss: () -> Void

    @EnvironmentObject private var metadataStore: MetadataStore
    @EnvironmentObject private var remindersService: RemindersService
    @State private var name = ""

    private var sections: [TaskSection] {
        remindersService.sections(forProject: project.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save \(project.title) as Template")
                .font(Theme.font(14, .semibold))

            TextField("Template name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            if sections.isEmpty {
                Text("This project has no sections yet, so the template will be empty.")
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
        metadataStore.saveTemplate(name: name, sectionNames: sections.map(\.name))
        onDismiss()
    }
}
