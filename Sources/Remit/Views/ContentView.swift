import SwiftUI

/// Everything selectable in the sidebar. Filters that don't correspond to a Reminders list
/// (Inbox/Today/Upcoming) are handled entirely in TaskListView -- see ROADMAP.md "Known traps"
/// for why the date-bucketing logic lives in one place (RemindersService) rather than here.
enum SidebarSelection: Hashable {
    case inbox
    case today
    case upcoming
    /// The Filters & Labels management page.
    case filtersAndLabels
    /// Every task carrying one label, across all projects.
    case label(String)
    /// A user-defined saved filter (#27).
    case filter(String)
    case project(String)
}

struct ContentView: View {
    @EnvironmentObject private var remindersService: RemindersService
    @EnvironmentObject private var metadataStore: MetadataStore
    @EnvironmentObject private var uiState: UIState
    @State private var selection: SidebarSelection? = .today
    /// Shared with the View menu's toggle in RemitApp via AppStorage rather than passed down, so
    /// the menu command and the split view can't drift out of sync -- the Electron build shipped a
    /// sidebar toggle that was "added" but not wired three separate times (ROADMAP.md #76-#78).
    @AppStorage("sidebar.visible") private var sidebarVisible = true

    var body: some View {
        VStack(spacing: 0) {
            // Above the split view, not inside the detail pane: a storage problem is not scoped to
            // whichever list happens to be selected, and ROADMAP.md's known traps include state
            // that exists in code but is never actually reachable on screen.
            if let warning = metadataStore.storageWarning {
                ErrorBanner(message: warning) { metadataStore.storageWarning = nil }
            }
            splitView
        }
        .sheet(isPresented: $uiState.paletteOpen) { paletteSheet }
        .sheet(isPresented: $uiState.settingsOpen) { SettingsWindow() }
        .sheet(isPresented: $uiState.shortcutsHelpOpen) { shortcutsSheet }
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
    private var shortcutsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { uiState.shortcutsHelpOpen = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ShortcutsSettings()
        }
        .frame(width: 420, height: 460)
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
