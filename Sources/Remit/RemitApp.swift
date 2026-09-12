import SwiftUI

@main
struct RemitApp: App {
    @StateObject private var remindersService = RemindersService()
    @StateObject private var metadataStore = MetadataStore()
    @StateObject private var displayPrefs = DisplayPrefsStore()
    @StateObject private var uiState = UIState()
    @StateObject private var shortcuts = ShortcutsStore()
    @AppStorage("sidebar.visible") private var sidebarVisible = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(remindersService)
                .environmentObject(metadataStore)
                .environmentObject(displayPrefs)
                .environmentObject(uiState)
                .environmentObject(shortcuts)
                .task {
                    // Deliberately does NOT request access here. Prompt #41 asked for an explicit
                    // "Connect to Apple Reminders" step rather than a permission dialog appearing
                    // unprompted on first launch; RemindersAccessPromptView owns that request.
                    if remindersService.authorizationGranted {
                        await remindersService.refreshAll()
                    }
                }
                // 640 keeps the window snappable to half of a 1440pt-wide display (720pt) with room
                // to spare; the old 900 floor was 62.5% of the screen, so half-screen tiling and
                // side-by-side with another window were both impossible.
                .frame(minWidth: 640, minHeight: 480)
        }
        // New windows still open roomy -- only the *floor* moved, not the default.
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo \(remindersService.undoDescription ?? "")") {
                    remindersService.performUndo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(remindersService.undoDescription == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Welcome Tour…") { uiState.onboardingOpen = true }
                Button("Keyboard Shortcuts") { uiState.shortcutsHelpOpen = true }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Quick Find...") { uiState.paletteOpen = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Settings...") { uiState.settingsOpen = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // The same history the trackpad swipe drives. Menu items make it discoverable, give it
            // the standard macOS shortcuts, and mean back/forward still works on a mouse.
            CommandGroup(after: .toolbar) {
                Button("Back") { uiState.navigateBack.toggle() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { uiState.navigateForward.toggle() }
                    .keyboardShortcut("]", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button(sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    sidebarVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}
