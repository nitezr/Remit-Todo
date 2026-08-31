import SwiftUI

/// v0.1 sidebar: fixed items + a flat project list. Nesting, favorites, drag-to-reorder, and the
/// Todoist-matched visual pass are tracked in ROADMAP.md "Sidebar & navigation" -- deliberately
/// not attempted here until the core loop (this file's simplest form) is proven against real
/// Reminders data.
struct SidebarView: View {
    @EnvironmentObject private var remindersService: RemindersService
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Inbox", systemImage: "tray")
                    .tag(SidebarSelection.inbox)
                Label("Today", systemImage: "calendar")
                    .tag(SidebarSelection.today)
                Label("Upcoming", systemImage: "calendar.badge.clock")
                    .tag(SidebarSelection.upcoming)
            }

            Section("My Projects") {
                ForEach(remindersService.projects) { project in
                    Label {
                        Text(project.title)
                    } icon: {
                        Circle()
                            .fill(Color(hex: project.colorHex))
                            .frame(width: 10, height: 10)
                    }
                    .tag(SidebarSelection.project(project.id))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}
