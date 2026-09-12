import AppKit
import EventKit
import SwiftUI

/// The welcome tour: what Remit is, the two permissions it needs and why, an optional practice
/// list, and the handful of keys worth learning first. Shown on first launch, and again from
/// Help → Welcome Tour.
///
/// Permissions are asked for here with the reason beside each, rather than as bare system dialogs
/// on launch (#41). Full Disk Access gets the most room because macOS has no prompt for it: the user
/// has to add Remit by hand, and Remit has to reopen before the grant applies -- so the current step
/// is persisted, and the tour picks up where it left off after that relaunch.
///
/// Every name shown is made up (Sam, Priya, Acme), so the tour looks the same on every Mac and
/// before any permission has been granted.
struct OnboardingView: View {
    @EnvironmentObject private var remindersService: RemindersService
    @EnvironmentObject private var shortcuts: ShortcutsStore
    @EnvironmentObject private var uiState: UIState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("onboarding.completed") private var completed = false
    @AppStorage("onboarding.step") private var stepRaw = Step.welcome.rawValue

    @State private var addingTour = false
    @State private var tourError: String?
    @State private var checking = false

    enum Step: Int, CaseIterable {
        case welcome, reminders, fullDiskAccess, practice, keys
    }

    private var step: Step { Step(rawValue: stepRaw) ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 18)

            ScrollView {
                Group {
                    switch step {
                    case .welcome: welcomeStep
                    case .reminders: remindersStep
                    case .fullDiskAccess: fullDiskAccessStep
                    case .practice: practiceStep
                    case .keys: keysStep
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.separator)
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 640, height: 600)
        .background(Theme.pageBackground)
        .interactiveDismissDisabled()
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                "checklist",
                "Welcome to Remit",
                "A Todoist-style home for Apple Reminders. Everything you do here is a change in Reminders itself, so it syncs to your iPhone, iPad and Mac. Remit keeps no copy of your tasks."
            )
            TourPreview()
            VStack(alignment: .leading, spacing: 10) {
                feature("number", "Tags, sections and list groups are Reminders' own — the same ones Reminders.app shows.")
                feature("rectangle.split.3x1", "List, Board and Calendar layouts, remembered for each view.")
                feature("keyboard", "Keyboard-first: completing, scheduling and tagging each take one key.")
            }
        }
    }

    private var remindersStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(
                "bell.badge",
                "Connect Apple Reminders",
                "Remit reads and writes your lists and tasks through Apple Reminders. macOS will ask you to allow it."
            )

            let status = EKEventStore.authorizationStatus(for: .reminder)
            if remindersService.authorizationGranted {
                statusRow(ok: true, "Connected — \(remindersService.projects.count) lists found.")
            } else if status == .denied || status == .restricted {
                statusRow(ok: false, "Reminders access is turned off for Remit.")
                Button("Open Privacy & Security") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
                note("Turn Remit on under Reminders, then come back to this step.")
            } else {
                Button("Connect Reminders") {
                    Task { await remindersService.requestAccess() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var fullDiskAccessStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(
                "lock.open",
                "Allow Full Disk Access",
                "Apple's public Reminders API has no tags, sections or list groups. Remit reads them straight from Reminders' own database — read-only — and macOS keeps that database behind Full Disk Access. Without it Remit still works, just without tags and sections."
            )

            if !remindersService.authorizationGranted {
                statusRow(ok: false, "Connect Reminders first — that's the previous step.")
            } else {
                switch remindersService.nativeStatus {
                case .available:
                    statusRow(ok: true, "Remit can read your tags and sections — \(remindersService.tags.count) tags found.")
                case .unavailable(let message):
                    statusRow(ok: false, message)
                case .needsFullDiskAccess, .unknown:
                    VStack(alignment: .leading, spacing: 12) {
                        instruction(1, "Open Full Disk Access in System Settings.") {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(NativeMetadataStatus.fullDiskAccessSettingsURL)
                            }
                        }
                        instruction(2, "Turn on Remit. If it isn't listed, click + and choose Remit in Applications.") {
                            EmptyView()
                        }
                        instruction(3, "macOS applies the change once Remit reopens. The tour continues from here.") {
                            Button("Reopen Remit", action: relaunch)
                        }
                    }
                    Button(checking ? "Checking…" : "Check Again") {
                        Task {
                            checking = true
                            await remindersService.refreshAll()
                            checking = false
                        }
                    }
                    .disabled(checking)
                }
            }
        }
    }

    private var practiceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(
                "graduationcap",
                "Practise on a tour list",
                "Remit can add a list called “\(TourContent.listName)” to your Reminders: nine tasks in three sections, each teaching one thing. Sam, Priya and Acme are made up. Delete the list when you're done."
            )

            VStack(alignment: .leading, spacing: 10) {
                ForEach(TourContent.sections, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section)
                            .font(Theme.font(12, .semibold))
                            .foregroundStyle(Theme.secondaryText)
                        ForEach(TourContent.tasks.filter { $0.section == section }) { task in
                            HStack(spacing: 8) {
                                Image(systemName: "circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.secondaryText)
                                Text(task.title)
                                    .font(Theme.font(12))
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator, lineWidth: 1))

            if let tour = remindersService.tourProject {
                statusRow(ok: true, "The tour list is in your Reminders.")
                Button("Open the Tour List") { finish(opening: tour.id) }
                    .buttonStyle(.borderedProminent)
            } else if !remindersService.authorizationGranted {
                note("Connect Reminders first to add the tour list.")
            } else {
                Button(addingTour ? "Adding…" : "Add Tour List", action: addTour)
                    .buttonStyle(.borderedProminent)
                    .disabled(addingTour)
                if remindersService.nativeStatus != .available {
                    note("Without Full Disk Access the tasks are added without their sections and tags.")
                }
            }

            if let tourError {
                Text(tourError)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.overdue)
            }
        }
    }

    private let keyActions: [ShortcutAction] = [
        .quickAdd, .completeTask, .scheduleToday, .scheduleTomorrow, .editLabels,
        .openDetail, .nextTask, .previousTask, .commandPalette, .shortcutsPanel,
    ]

    private var keysStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(
                "keyboard",
                "A few keys to start with",
                "Select a task with a click, or with J and K, then act on it with one key. Change any of these in Settings → Shortcuts."
            )

            VStack(spacing: 0) {
                ForEach(Array(keyActions.enumerated()), id: \.offset) { index, action in
                    if index > 0 { Divider().overlay(Theme.separator) }
                    HStack {
                        Text(action.title)
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.primaryText)
                        Spacer()
                        KeyCapRow(bindings: shortcuts.bindings(for: action), emphasized: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator, lineWidth: 1))
        }
    }

    // MARK: - Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Theme.accent : Theme.separator)
                    .frame(width: item == step ? 22 : 8, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: stepRaw)
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { go(-1) }
            }
            Spacer()
            if step != .keys {
                Button("Skip Tour") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.trailing, 8)
            }
            Button(step == .keys ? "Start Using Remit" : "Continue") {
                if step == .keys { finish() } else { go(1) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func heading(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(Theme.font(24, .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(subtitle)
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            Text(text)
                .font(Theme.font(13))
                .foregroundStyle(Theme.primaryText)
        }
    }

    private func statusRow(ok: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(text)
                .font(Theme.font(13))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill((ok ? Color.green : Color.orange).opacity(0.1)))
    }

    private func instruction<Accessory: View>(
        _ number: Int,
        _ text: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(Theme.font(12, .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
            Text(text)
                .font(Theme.font(13))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            accessory()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private func go(_ delta: Int) {
        stepRaw = min(max(stepRaw + delta, 0), Step.allCases.count - 1)
    }

    private func finish(opening projectID: String? = nil) {
        completed = true
        stepRaw = Step.welcome.rawValue
        if let id = projectID ?? remindersService.tourProject?.id {
            uiState.pendingNavigation = .project(id)
        }
        dismiss()
    }

    private func addTour() {
        addingTour = true
        tourError = nil
        Task {
            do {
                try await remindersService.createTourList()
            } catch {
                tourError = error.localizedDescription
            }
            addingTour = false
        }
    }

    /// Full Disk Access is read when a process starts, so the grant needs a fresh launch. A shell
    /// waits for this process to exit, then opens the app again.
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// The welcome step's picture of Remit: a Today list of made-up tasks, so it looks the same on every
/// Mac and before any permission has been granted.
private struct TourPreview: View {
    private struct Row {
        let title: String
        let project: String
        let tags: [String]
        let due: String
        let dueIsToday: Bool
        let priority: Priority
    }

    private let rows = [
        Row(title: "Send Sam the launch plan", project: "🤝 Acme", tags: ["Sam👤", "⏳waiting"], due: "Today", dueIsToday: true, priority: .p1),
        Row(title: "Review Priya's design notes", project: "🌟 Orbit", tags: ["Priya👤", "💬discuss"], due: "Tomorrow", dueIsToday: false, priority: .p2),
        Row(title: "Pay the internet bill", project: "🏠 Home", tags: ["🔁Monthly"], due: "Friday", dueIsToday: false, priority: .p4),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today")
                .font(Theme.font(13, .semibold))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider().overlay(Theme.separator).padding(.leading, 39)
                }
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .strokeBorder(Theme.priority(row.priority), lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title)
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.primaryText)
                        HStack(spacing: 6) {
                            Text(row.due)
                                .font(Theme.font(11))
                                .foregroundStyle(row.dueIsToday ? Color.green : Theme.secondaryText)
                            ForEach(row.tags, id: \.self) { tag in
                                LabelChip(label: ReminderTag(name: tag))
                            }
                            Spacer(minLength: 0)
                            Text(row.project)
                                .font(Theme.font(11))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator, lineWidth: 1))
    }
}
