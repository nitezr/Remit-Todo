import SwiftUI

/// The task detail panel (ROADMAP.md #47), laid out like the Glaze build's: a breadcrumb header
/// with prev/next/delete/close, the title and description on the left, and every attribute in a
/// right-hand rail.
///
/// Prompt #4 was explicit that clicking a row must not auto-open a docked inspector, so this stays
/// a sheet you open deliberately (double-click, `i`, or Return) and close with Escape.
///
/// Edits to title, description, and location are committed on blur or close rather than on every
/// keystroke -- each write is a full EventKit save, and doing that per character would hammer the
/// store and fight iCloud sync.
struct TaskDetailPeek: View {
    let task: RemitTask
    /// Prev/next walk the same order the list renders, so the arrows match what's on screen.
    var siblings: [RemitTask] = []
    var onNavigate: ((RemitTask) -> Void)?
    var onDismiss: () -> Void

    @EnvironmentObject private var remindersService: RemindersService
    @EnvironmentObject private var metadataStore: MetadataStore

    @State private var title = ""
    @State private var notes = ""
    @State private var location = ""
    @State private var labelQuery = ""
    @State private var dueDate = Date()
    @State private var hasDate = false
    @State private var isAllDay = true
    @State private var repeatRule: RepeatOption = .none
    @State private var confirmingDelete = false

    /// The repeat presets offered in the picker. Anything more exotic set elsewhere shows as
    /// "Custom" and is left alone unless the user picks a new value.
    enum RepeatOption: String, CaseIterable, Identifiable {
        case none, daily, weekly, monthly, yearly, custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "No repeat"
            case .daily: return "Every day"
            case .weekly: return "Every week"
            case .monthly: return "Every month"
            case .yearly: return "Every year"
            case .custom: return "Custom"
            }
        }

        var recurrence: QuickAddRecurrence? {
            switch self {
            case .none, .custom: return nil
            case .daily: return QuickAddRecurrence(frequency: .daily)
            case .weekly: return QuickAddRecurrence(frequency: .weekly)
            case .monthly: return QuickAddRecurrence(frequency: .monthly)
            case .yearly: return QuickAddRecurrence(frequency: .yearly)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                mainPane
                Divider()
                sidebar
            }
        }
        .frame(width: 880, height: 660)
        .background(Theme.pageBackground)
        .onAppear(perform: load)
        .onChange(of: task.id) { load() }
        .onExitCommand { commitText(); onDismiss() }
        .confirmationDialog("Delete this task?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Task", role: .destructive) {
                write { try remindersService.delete(task) }
                onDismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes it from Apple Reminders on all your devices.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "number")
                .font(Theme.font(11))
                .foregroundStyle(Theme.secondaryText)
            Text(projectName)
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)

            Spacer()

            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(neighbour(-1) == nil)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(neighbour(1) == nil)
            Button { confirmingDelete = true } label: {
                Image(systemName: "trash").foregroundStyle(Theme.overdue)
            }
            .buttonStyle(.plain)
            Button { commitText(); onDismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Main pane

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    remindersService.completeAnimated(task)
                    onDismiss()
                } label: {
                    Image(systemName: "circle")
                        .font(.system(size: 21))
                        .foregroundStyle(Theme.priority(task.priority))
                }
                .buttonStyle(.plain)

                TextField("Task name", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.font(22, .semibold))
                    .onSubmit(commitText)
            }

            TextEditor(text: $notes)
                .font(Theme.font(13))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 11))
                            Text("Description")
                                .font(Theme.font(13))
                        }
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                    }
                }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                field("Project") {
                    Picker("", selection: projectBinding) {
                        ForEach(remindersService.projects) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                }

                if !projectSections.isEmpty {
                    field("Section") {
                        Picker("", selection: sectionBinding) {
                            Text("No section").tag(String?.none)
                            ForEach(projectSections) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .labelsHidden()
                    }
                }

                field("Date") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "calendar").foregroundStyle(Theme.secondaryText)
                            if hasDate {
                                DatePicker(
                                    "",
                                    selection: $dueDate,
                                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                                )
                                .labelsHidden()
                                .onChange(of: dueDate) { commitDate() }
                            } else {
                                Button("Add date") {
                                    hasDate = true
                                    dueDate = Calendar.current.startOfDay(for: Date())
                                    commitDate()
                                }
                                .buttonStyle(.link)
                            }
                            Spacer()
                            if hasDate {
                                Button {
                                    hasDate = false
                                    write { try remindersService.setDueDate(nil, allDay: true, for: task) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Theme.secondaryText)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if hasDate {
                            Toggle("All-day", isOn: $isAllDay)
                                .toggleStyle(.switch)
                                .font(Theme.font(11))
                                .onChange(of: isAllDay) { commitDate() }
                        }
                    }
                }

                field("Repeat") {
                    Picker("", selection: $repeatRule) {
                        ForEach(RepeatOption.allCases) { option in
                            // "Custom" is only offered when the task already has an exotic rule.
                            if option != .custom || repeatRule == .custom {
                                Text(option.label).tag(option)
                            }
                        }
                    }
                    .labelsHidden()
                    .onChange(of: repeatRule) {
                        guard repeatRule != .custom else { return }
                        write { try remindersService.setRecurrence(repeatRule.recurrence, for: task) }
                    }
                }

                field("Priority") {
                    Picker("", selection: priorityBinding) {
                        ForEach(Priority.allCases) { priority in
                            Text("P\(priorityNumber(priority))").tag(priority)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                field("Tags") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Search or add tags", text: $labelQuery)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.font(11))
                            .onSubmit(addQueriedTag)

                        LabelFlow(labels: filteredLabels, assigned: assignedLabelIDs) { label in
                            toggleLabel(label)
                        }

                        if !labelQuery.isEmpty,
                           !filteredLabels.contains(where: { $0.name.caseInsensitiveCompare(labelQuery) == .orderedSame }) {
                            Button("Add #\(labelQuery)") { addQueriedTag() }
                                .buttonStyle(.link)
                                .font(Theme.font(11))
                        }
                    }
                }

                field("Location") {
                    TextField("Add location", text: $location)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.font(11))
                        .onSubmit { write { try remindersService.setLocation(location, for: task) } }
                }
            }
            .padding(14)
        }
        .frame(width: 268)
        .background(Theme.columnBackground)
        .background(Theme.sidebarBackground)
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.font(12, .semibold))
                .foregroundStyle(Theme.secondaryText)
            content()
            // A rule under each field, matching the reference. Spacing alone left the rail
            // reading as one long column rather than a set of separate attributes.
            Divider().overlay(Theme.separator).padding(.top, 4)
        }
    }

    // MARK: - Bindings

    private var projectBinding: Binding<String> {
        Binding(
            get: { task.projectID },
            set: { newProjectID in
                write { try remindersService.moveTask(task, toProject: newProjectID) }
            }
        )
    }

    private var sectionBinding: Binding<String?> {
        Binding(
            get: { remindersService.current(task).sectionID },
            set: { remindersService.setSection($0, for: task) }
        )
    }

    private var priorityBinding: Binding<Priority> {
        Binding(
            get: { task.priority },
            set: { newPriority in
                write { try remindersService.setPriority(newPriority, for: task) }
            }
        )
    }

    private func priorityNumber(_ priority: Priority) -> Int {
        switch priority {
        case .p1: return 1
        case .p2: return 2
        case .p3: return 3
        case .p4: return 4
        }
    }

    // MARK: - Data

    private var projectName: String {
        remindersService.projects.first { $0.id == task.projectID }?.title ?? "Project"
    }

    private var projectSections: [TaskSection] {
        remindersService.sections(forProject: task.projectID)
    }

    private var assignedLabelIDs: Set<String> {
        Set(remindersService.current(task).labels)
    }

    /// Every Reminders tag, plus any on this task the last read hasn't listed yet.
    private var filteredLabels: [ReminderTag] {
        var tags = remindersService.tags
        for name in remindersService.current(task).labels where !tags.contains(where: { $0.name == name }) {
            tags.append(ReminderTag(name: name))
        }
        guard !labelQuery.isEmpty else { return tags }
        return tags.filter { $0.name.localizedCaseInsensitiveContains(labelQuery) }
    }

    private func toggleLabel(_ label: ReminderTag) {
        var names = remindersService.current(task).labels
        if names.contains(label.name) {
            names.removeAll { $0 == label.name }
        } else {
            names.append(label.name)
        }
        remindersService.setTags(names, for: task)
    }

    private func addQueriedTag() {
        let name = labelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        remindersService.setTags(remindersService.current(task).labels + [name], for: task)
        labelQuery = ""
    }

    private func neighbour(_ delta: Int) -> RemitTask? {
        guard let index = siblings.firstIndex(where: { $0.id == task.id }) else { return nil }
        let target = index + delta
        guard target >= 0, target < siblings.count else { return nil }
        return siblings[target]
    }

    private func step(_ delta: Int) {
        guard let next = neighbour(delta) else { return }
        commitText()
        onNavigate?(next)
    }

    // MARK: - Loading and saving

    private func load() {
        title = task.title
        notes = task.notes ?? ""
        location = remindersService.location(for: task) ?? ""
        hasDate = task.dueDate != nil
        dueDate = task.dueDate ?? Calendar.current.startOfDay(for: Date())
        isAllDay = !task.hasDueTime
        labelQuery = ""

        if let existing = remindersService.recurrence(for: task) {
            // Only the plain every-N-units presets map cleanly back onto the picker.
            switch (existing.frequency, existing.interval, existing.daysOfWeek) {
            case (.daily, 1, nil): repeatRule = .daily
            case (.weekly, 1, nil): repeatRule = .weekly
            case (.monthly, 1, nil): repeatRule = .monthly
            case (.yearly, 1, nil): repeatRule = .yearly
            default: repeatRule = .custom
            }
        } else {
            repeatRule = .none
        }
    }

    private func commitDate() {
        guard hasDate else { return }
        write { try remindersService.setDueDate(dueDate, allDay: isAllDay, for: task) }
    }

    /// Text fields save on blur/close rather than per keystroke -- see the type doc.
    private func commitText() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != task.title {
            write { try remindersService.setTitle(trimmedTitle, for: task) }
        }
        if notes != (task.notes ?? "") {
            write { try remindersService.setNotes(notes.isEmpty ? nil : notes, for: task) }
        }
        if location != (remindersService.location(for: task) ?? "") {
            write { try remindersService.setLocation(location, for: task) }
        }
    }

    private func write(_ action: () throws -> Void) {
        do {
            try action()
            Task { await remindersService.refreshAll() }
        } catch {
            remindersService.lastError = error.localizedDescription
        }
    }
}

/// Wrapping chip list for tags. SwiftUI has no flow layout before macOS 13's `Layout`, so this
/// is a small one -- a plain HStack would clip with this many labels.
struct LabelFlow: View {
    let labels: [ReminderTag]
    let assigned: Set<String>
    var onTap: (ReminderTag) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(labels) { label in
                let isOn = assigned.contains(label.id)
                HStack(spacing: 3) {
                    Image(systemName: "number")
                        .font(.system(size: 8))
                    Text(label.name)
                        .font(Theme.font(11))
                }
                .foregroundStyle(isOn ? label.color : Theme.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(label.color.opacity(isOn ? 0.18 : 0.06))
                )
                .overlay(
                    Capsule().stroke(label.color.opacity(isOn ? 0.8 : 0.25), lineWidth: 1)
                )
                .contentShape(Capsule())
                .onTapGesture { onTap(label) }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
