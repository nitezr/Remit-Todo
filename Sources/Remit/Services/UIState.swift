import SwiftUI

/// App-wide UI flags driven from the menu bar.
///
/// ⌘K and ⌘Z were originally handled in the task list's NSEvent monitor and didn't fire: menu key
/// equivalents are resolved by AppKit before a local monitor sees them, and a command with no menu
/// item is also undiscoverable. Real menu items own these now, and flip flags here.
@MainActor
final class UIState: ObservableObject {
    @Published var paletteOpen = false
    @Published var settingsOpen = false
    @Published var shortcutsHelpOpen = false
    /// Set by the palette when it picks a destination; ContentView applies it to the sidebar.
    @Published var pendingNavigation: SidebarSelection?
    @Published var pendingTaskID: String?
}
