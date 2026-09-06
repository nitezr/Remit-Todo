import AppKit
import SwiftUI

/// Multi-tab settings (ROADMAP.md #74). Reachable from the sidebar gear and ⌘, -- the Electron
/// build repeatedly shipped settings that existed in code but couldn't be reached in the UI
/// (#18, #30, #36, #39), so discoverability is the point of this screen, not a detail.
struct SettingsWindow: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            ShortcutsSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AutomationSettings()
                .tabItem { Label("Automation", systemImage: "terminal") }
            DataSettings()
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 480, height: 420)
        .overlay(alignment: .bottomTrailing) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(12)
        }
    }
}

/// Reference list of every binding. Remapping is not built yet -- rather than ship a picker that
/// silently doesn't rebind anything (the exact failure #76-#78 describes), this states the fact.
struct ShortcutsSettings: View {
    private let groups: [(String, [(String, String)])] = [
        ("Navigation", [
            ("j / \u{2193}", "Next task"),
            ("k / \u{2191}", "Previous task"),
            ("\u{2318}K  or  /", "Command palette / search"),
            ("\u{2318}S", "Toggle sidebar"),
            ("?", "This shortcuts panel"),
            ("\u{2190} \u{2192}", "Move between board columns"),
        ]),
        ("Tasks", [
            ("e", "Complete task"),
            ("1 - 4", "Priority 1-4"),
            ("l", "Edit labels"),
            ("i / \u{21A9}", "Open task detail"),
            ("q / a", "Quick add"),
            ("\u{2318}\u{232B}", "Delete task"),
            ("\u{2318}Z", "Undo last change"),
        ]),
        ("Schedule", [
            ("t", "Today"),
            ("u / m", "Tomorrow"),
            ("w", "This weekend"),
            ("n", "Next week"),
            ("0 / \u{21E7}T", "Remove due date"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.0)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(group.1, id: \.0) { binding in
                            HStack {
                                Text(binding.0)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 90, alignment: .leading)
                                Text(binding.1)
                                    .font(.system(size: 12))
                                Spacer()
                            }
                        }
                    }
                }

                Text("Remapping is not built yet — these bindings are fixed. They match the Glaze build's defaults.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(16)
        }
    }
}

struct GeneralSettings: View {
    @AppStorage("general.hideSleepingHours") private var hideSleepingHours = false
    @AppStorage("general.sleepStartHour") private var sleepStartHour = 22
    @AppStorage("general.sleepEndHour") private var sleepEndHour = 8
    @AppStorage("general.completionSound") private var completionSound = true

    var body: some View {
        Form {
            Section("Time-based views") {
                Toggle("Hide sleeping hours", isOn: $hideSleepingHours)
                // Defaults to 10PM-8AM per #10, user-configurable.
                Picker("From", selection: $sleepStartHour) {
                    ForEach(0..<24, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                }
                .disabled(!hideSleepingHours)
                Picker("Until", selection: $sleepEndHour) {
                    ForEach(0..<24, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                }
                .disabled(!hideSleepingHours)
            }

            Section("Feedback") {
                Toggle("Play a sound when completing a task", isOn: $completionSound)
            }
        }
        .formStyle(.grouped)
    }

    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

/// Disconnect / start fresh (#36). Wipes only Remit's own layer -- labels, sections, favourites,
/// nesting, emoji -- and never touches a single reminder.
struct DataSettings: View {
    @EnvironmentObject private var metadataStore: MetadataStore
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remit layer")
                .font(.system(size: 13, weight: .semibold))
            Text("""
                Labels, sections, favourites, sub-project nesting, and project emoji are stored by \
                Remit, because Apple Reminders has nowhere to put them. Your tasks and lists always \
                live in Reminders and are never stored here.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button("Reset Remit Data...", role: .destructive) { confirming = true }

            Text("This deletes the Remit layer only. Every task and list stays in Apple Reminders.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
        .confirmationDialog("Reset all Remit data?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { metadataStore.resetAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Labels, sections, favourites, nesting, and emoji will be erased. Your Reminders tasks and lists are not affected.")
        }
    }
}


/// Automation / agent access (ROADMAP.md #18, #30, #36, #39).
///
/// Those four prompts are the same request made four times: an MCP/automation setting that kept
/// either not shipping or not being findable. So this tab states plainly what exists, where it is,
/// and whether it's on your PATH -- rather than a toggle whose effect you can't verify.
///
/// The automation surface is a **command-line tool**, not a server inside the app. An embedded
/// HTTP/MCP server would put a listening socket and a request loop in the UI process, where one
/// hung request takes the window down with it. `remit-cli` starts, does one thing, and exits, so
/// nothing it does can destabilise the app. Agents (Claude Code included) drive it by shelling out.
struct AutomationSettings: View {
    @State private var copied = false

    /// The CLI ships inside the app bundle, so this resolves for an installed copy and a dev build
    /// alike.
    private var toolPath: String? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("remit-cli")
            .path
    }

    private var isOnPath: Bool {
        ["/usr/local/bin/remit", "\(NSHomeDirectory())/.local/bin/remit"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    private var installCommand: String {
        guard let toolPath else { return "" }
        return "ln -sf \"\(toolPath)\" /usr/local/bin/remit"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Command-line access")
                    .font(Theme.font(13, .semibold))

                Text("""
                    Remit ships a command-line tool so AI agents and scripts can read and write \
                    your tasks. It talks to Apple Reminders directly and exits immediately — there \
                    is no server, no open port, and nothing running in the background.
                    """)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.secondaryText)

                statusRow(
                    "Tool installed in app bundle",
                    ok: toolPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                )
                statusRow("Available on PATH as `remit`", ok: isOnPath)

                if let toolPath {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Path")
                            .font(Theme.font(11, .semibold))
                            .foregroundStyle(Theme.secondaryText)
                        Text(toolPath)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }

                if !isOnPath {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("To use it as `remit` anywhere, run this in Terminal:")
                            .font(Theme.font(11))
                            .foregroundStyle(Theme.secondaryText)
                        HStack {
                            Text(installCommand)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer()
                            Button(copied ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(installCommand, forType: .string)
                                copied = true
                            }
                            .buttonStyle(.link)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.columnBackground))
                        Text("Remit does not write outside its own folder, so this step is yours to run.")
                            .font(Theme.font(10))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }

                Divider()

                Text("Commands")
                    .font(Theme.font(12, .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Self.commands, id: \.0) { command, description in
                        HStack(alignment: .top, spacing: 8) {
                            Text(command)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(width: 190, alignment: .leading)
                            Text(description)
                                .font(Theme.font(10))
                                .foregroundStyle(Theme.secondaryText)
                            Spacer()
                        }
                    }
                }

                Text("""
                    The tool asks for its own Reminders permission the first time it runs, because \
                    macOS grants access per binary. Labels and sections are read from Remit's own \
                    data file; the tool never writes that file, so it cannot conflict with the app.
                    """)
                    .font(Theme.font(10))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 4)
            }
            .padding(16)
        }
    }

    private func statusRow(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Theme.today : Theme.secondaryText)
            Text(label).font(Theme.font(11))
            Spacer()
        }
    }

    private static let commands: [(String, String)] = [
        ("remit projects", "List every project with open task counts"),
        ("remit list", "All open tasks as JSON"),
        ("remit list --project Work", "Open tasks in one project"),
        ("remit list --due today", "today, tomorrow, or overdue"),
        ("remit list --all", "Include completed tasks"),
        ("remit add \"Title\"", "Create a task in the default list"),
        ("  --project X --due tomorrow", "...with a project and date"),
        ("  --priority 1 --notes \"...\"", "...with priority and notes"),
        ("remit complete <id>", "Mark a task done"),
        ("remit delete <id>", "Delete a task"),
    ]
}
