import SwiftUI

/// Everything selectable in the sidebar. Filters that don't correspond to a Reminders list
/// (Inbox/Today/Upcoming) are handled entirely in TaskListView -- see ROADMAP.md "Known traps"
/// for why the date-bucketing logic lives in one place (RemindersService) rather than here.
enum SidebarSelection: Hashable {
    case inbox
    case today
    case upcoming
    /// The Filters & Tags management page.
    case filtersAndLabels
    /// Every task carrying one Reminders tag, by name, across all projects.
    case label(String)
    /// A user-defined saved filter (#27).
    case filter(String)
    case project(String)
}

struct ContentView: View {
    @EnvironmentObject private var remindersService: RemindersService
    @EnvironmentObject private var metadataStore: MetadataStore
    @EnvironmentObject private var uiState: UIState
    @EnvironmentObject private var shortcuts: ShortcutsStore
    @State private var selection: SidebarSelection? = .today
    @StateObject private var history = NavigationHistory(start: .today)
    @StateObject private var swipeMonitor = SwipeMonitor()
    /// Read only so the whole hierarchy re-renders when the font setting changes. Theme.font reads
    /// the value at render time, so without an observer here the switch would need a relaunch.
    @AppStorage("general.interfaceFont") private var interfaceFont = Theme.InterfaceFont.avenir.rawValue
    /// Shared with the View menu's toggle in RemitApp via AppStorage rather than passed down, so
    /// the menu command and the split view can't drift out of sync -- the Electron build shipped a
    /// sidebar toggle that was "added" but not wired three separate times (ROADMAP.md #76-#78).
    @AppStorage("sidebar.visible") private var sidebarVisible = true
    /// Per launch on purpose: the permission is still missing next time, so it should say so again.
    @State private var fullDiskAccessDismissed = false
    @AppStorage("onboarding.completed") private var onboardingCompleted = false

    var body: some View {
        VStack(spacing: 0) {
            // Above the split view, not inside the detail pane: a storage problem is not scoped to
            // whichever list happens to be selected, and ROADMAP.md's known traps include state
            // that exists in code but is never actually reachable on screen.
            if let warning = metadataStore.storageWarning {
                ErrorBanner(message: warning) { metadataStore.storageWarning = nil }
            }
            // Without this, missing tags and sections look like lost data rather than a permission.
            if remindersService.authorizationGranted,
               remindersService.nativeStatus == .needsFullDiskAccess,
               !fullDiskAccessDismissed {
                FullDiskAccessBanner { fullDiskAccessDismissed = true }
            }
            splitView
        }
        // Every selection change routes through the history so a click, a palette result and a
        // swipe all stay in step. `history.current` is the source of truth; `selection` follows it.
        .onChange(of: selection) { _, new in
            guard new != history.current else { return }
            history.visit(new)
        }
        .onAppear {
            if !onboardingCompleted { uiState.onboardingOpen = true }
            swipeMonitor.install { direction in
                let destination = direction == .back ? history.goBack() : history.goForward()
                guard let destination else { return false }  // let the event through at either end
                selection = destination
                return true
            }
        }
        .onDisappear { swipeMonitor.remove() }
        // The menu items signal through UIState because a CommandGroup lives outside the view
        // hierarchy and cannot reach this view's history directly.
        .onChange(of: uiState.navigateBack) { _, _ in
            if let destination = history.goBack() { selection = destination }
        }
        .onChange(of: uiState.navigateForward) { _, _ in
            if let destination = history.goForward() { selection = destination }
        }
        // Destinations requested from outside the sidebar, such as the welcome tour opening its
        // practice list. Cleared once applied, so the same request can be made again later.
        .onChange(of: uiState.pendingNavigation) { _, destination in
            guard let destination else { return }
            selection = destination
            uiState.pendingNavigation = nil
        }
        .sheet(isPresented: $uiState.paletteOpen) { paletteSheet }
        .sheet(isPresented: $uiState.settingsOpen) { SettingsWindow() }
        .sheet(isPresented: $uiState.shortcutsHelpOpen) { shortcutsSheet }
        .sheet(isPresented: $uiState.onboardingOpen) { OnboardingView() }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(selection: $selection)
        } detail: {
            if !remindersService.authorizationGranted {
                RemindersAccessPromptView()
            } else if selection == .filtersAndLabels {
                LabelsPage(selection: $selection)
            } else if let selection {
                TaskListView(selection: selection) { destination in
                    self.selection = destination
                }
                .id(selection)
            } else {
                ContentUnavailableView("Select a view", systemImage: "checklist")
            }
        }
    }

    // A sheet rather than a docked panel: #35 was a real layout bug where a sticky shortcuts
    // panel ate the project list's scroll space when both were visible.
    //
    // This is the read-only reference. It used to embed the settings panel, which meant the help
    // sheet and the editor were the same cramped 420x460 view doing two jobs badly; editing now
    // lives in Settings and this just answers "what key does what", in two columns so the whole
    // set is visible at once instead of scrolling past the fold.
    private var shortcutsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(Theme.font(15, .semibold))
                Spacer()
                Button("Customize…") {
                    uiState.shortcutsHelpOpen = false
                    uiState.settingsOpen = true
                }
                .buttonStyle(.link)
                .font(Theme.font(12))
                Button("Done") { uiState.shortcutsHelpOpen = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().overlay(Theme.separator)

            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 18) {
                        shortcutGroup(.navigation)
                        shortcutGroup(.schedule)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        shortcutGroup(.tasks)
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 620, height: 520)
    }

    private func shortcutGroup(_ group: ShortcutAction.Group) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(group.rawValue)
                .font(Theme.font(11, .semibold))
                .foregroundStyle(Theme.secondaryText)
                .textCase(.uppercase)
                .padding(.bottom, 2)

            ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                HStack(spacing: 10) {
                    Text(action.title)
                        .font(Theme.font(13))
                    Spacer(minLength: 14)
                    KeyCapRow(bindings: shortcuts.bindings(for: action))
                }
            }
            ForEach(
                Array(ShortcutAction.fixedBindings.filter { $0.group == group }.enumerated()),
                id: \.offset
            ) { _, item in
                HStack(spacing: 10) {
                    Text(item.title)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 14)
                    KeyCap(text: item.keys)
                }
            }
        }
    }

    @ViewBuilder
    private var paletteSheet: some View {
        CommandPalette(
            tasks: remindersService.tasks,
            projects: remindersService.projects,
            onSelectTask: { task in
                // Jump to the task's project so the row is actually on screen when selected.
                uiState.pendingTaskID = task.id
                selection = .project(task.projectID)
            },
            onSelectView: { selection = $0 },
            onDismiss: { uiState.paletteOpen = false }
        )
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 != .detailOnly }
        )
    }
}

struct RemindersAccessPromptView: View {
    @EnvironmentObject private var remindersService: RemindersService

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.badge")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Connect Apple Reminders")
                .font(.title2.bold())
            Text("Remit reads and writes your tasks through Apple Reminders. Nothing is stored anywhere else.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Connect") {
                Task { await remindersService.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
            if let lastError = remindersService.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
