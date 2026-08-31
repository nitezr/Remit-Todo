import SwiftUI

/// Everything selectable in the sidebar. Filters that don't correspond to a Reminders list
/// (Inbox/Today/Upcoming) are handled entirely in TaskListView -- see ROADMAP.md "Known traps"
/// for why the date-bucketing logic lives in one place (RemindersService) rather than here.
enum SidebarSelection: Hashable {
    case inbox
    case today
    case upcoming
    case project(String)
}

struct ContentView: View {
    @EnvironmentObject private var remindersService: RemindersService
    @State private var selection: SidebarSelection? = .today

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            if !remindersService.authorizationGranted {
                RemindersAccessPromptView()
            } else if let selection {
                TaskListView(selection: selection)
                    .id(selection)
            } else {
                ContentUnavailableView("Select a view", systemImage: "checklist")
            }
        }
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
