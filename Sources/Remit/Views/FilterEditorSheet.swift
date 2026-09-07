import SwiftUI

/// Create or edit a saved filter.
///
/// Filters were previously only reachable by setting options in a view's Display menu and choosing
/// "Save as Filter" -- which meant the Filters & Labels page, the obvious place to look, had no way
/// to make one. Worse, that route is disabled until a criterion is set, so the affordance is
/// invisible exactly when you have nothing yet and most need it.
///
/// The live count updates as criteria change, so you can tell an over-narrow filter from a useful
/// one before saving it rather than after.
struct FilterEditorSheet: View {
    /// Nil creates a new filter; non-nil edits that one in place.
    var existing: SavedFilter?
    var onDismiss: () -> Void

    @EnvironmentObject private var metadataStore: MetadataStore
    @EnvironmentObject private var remindersService: RemindersService

    @State private var name = ""
    @State private var deadline: DeadlineFilter = .all
    @State private var priority = "all"
    @State private var labelID = "all"
    @State private var projectID: String?

    private var isEditing: Bool { existing != nil }

    private var draft: SavedFilter {
        SavedFilter(
            id: existing?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            deadline: deadline,
            priority: priority,
            labelID: labelID,
            projectID: projectID
        )
    }

    /// Exactly the predicate the sidebar and list use, so the number shown here is the number you
    /// get after saving rather than an estimate computed a second way.
    private var matchCount: Int {
        remindersService.tasks.filter { task in
            !task.isCompleted
                && draft.matches(task, labelIDs: metadataStore.labels(forTask: task.id).map(\.id))
        }.count
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit Filter" : "New Filter")
                    .font(Theme.font(15, .semibold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().overlay(Theme.separator)

            Form {
                Section {
                    TextField("Name", text: $name)
                }

                Section("Criteria") {
                    Picker("Deadline", selection: $deadline) {
                        ForEach(DeadlineFilter.allCases) { Text($0.label).tag($0) }
                    }

                    Picker("Priority", selection: $priority) {
                        Text("Any").tag("all")
                        ForEach(Priority.allCases) { Text($0.label).tag(String($0.rawValue)) }
                    }

                    Picker("Label", selection: $labelID) {
                        Text("Any").tag("all")
                        ForEach(metadataStore.labels) { Text($0.name).tag($0.id) }
                    }

                    Picker("Project", selection: $projectID) {
                        Text("All projects").tag(String?.none)
                        ForEach(remindersService.projects) { Text($0.title).tag(String?.some($0.id)) }
                    }
                }

                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(Theme.secondaryText)
                        Text(matchCount == 1 ? "1 task matches now" : "\(matchCount) tasks match now")
                            .font(Theme.font(12))
                            .foregroundStyle(matchCount == 0 ? Theme.overdue : Theme.secondaryText)
                    }
                }
            }
            .formStyle(.grouped)

            Divider().overlay(Theme.separator)

            HStack {
                if isEditing, let existing {
                    Button("Delete", role: .destructive) {
                        metadataStore.removeFilter(existing.id)
                        onDismiss()
                    }
                }
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 480)
        .onAppear(perform: load)
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        deadline = existing.deadline
        priority = existing.priority
        labelID = existing.labelID
        projectID = existing.projectID
    }

    private func save() {
        guard canSave else { return }
        if isEditing {
            metadataStore.updateFilter(draft)
        } else {
            _ = metadataStore.addFilter(draft)
        }
        onDismiss()
    }
}
