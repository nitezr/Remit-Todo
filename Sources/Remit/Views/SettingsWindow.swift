import AppKit
import SwiftUI

/// Multi-tab settings (ROADMAP.md #74). Reachable from the sidebar gear and ⌘, -- the Electron
/// build repeatedly shipped settings that existed in code but couldn't be reached in the UI
/// (#18, #30, #36, #39), so discoverability is the point of this screen, not a detail.
struct SettingsWindow: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
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

            Divider().overlay(Theme.separator)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        // The old 480x420 clipped the shortcuts list, and Done floated on top of the rows it
        // covered. Bigger, and Done sits in its own bar below the tabs rather than over them.
        .frame(width: 640, height: 600)
    }
}

/// Real remapping (ROADMAP.md #74).
///
/// #76-#78 are three rounds of a shortcut being "added" and not actually working, so this panel is
/// wired to the same store `TaskListView` dispatches from -- there is no second copy of the
/// bindings to drift out of sync. Rebinding here changes behaviour immediately, with no restart.
struct ShortcutsSettings: View {
    @EnvironmentObject private var shortcuts: ShortcutsStore
    @State private var recordingAction: ShortcutAction?
    @State private var recording = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ShortcutAction.Group.allCases) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.rawValue)
                                .font(Theme.font(11, .semibold))
                                .foregroundStyle(Theme.secondaryText)
                                .textCase(.uppercase)
                                .padding(.bottom, 4)

                            ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                                row(action)
                            }

                            let fixed = ShortcutAction.fixedBindings.filter { $0.group == group }
                            ForEach(Array(fixed.enumerated()), id: \.offset) { _, item in
                                fixedRow(keys: item.keys, title: item.title)
                            }
                        }
                    }
                }
                .padding(18)
            }

            Divider().overlay(Theme.separator)

            HStack(spacing: 8) {
                if let note {
                    Text(note)
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                } else {
                    Text("Click a shortcut to record a new key. Esc cancels.")
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Reset All") {
                    shortcuts.resetAll()
                    note = "All shortcuts restored to defaults."
                }
                .buttonStyle(.link)
                .font(Theme.font(11))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .background(ShortcutRecorder(recording: $recording) { binding in
            guard let action = recordingAction else { return }
            if let stolen = shortcuts.assign(binding, to: action) {
                note = "\(binding.display) was on \(stolen.title); it now runs \(action.title)."
            } else {
                note = "\(action.title) is now \(binding.display)."
            }
            recordingAction = nil
        })
    }

    private func row(_ action: ShortcutAction) -> some View {
        let isRecording = recordingAction == action
        return HStack(spacing: 10) {
            Text(action.title)
                .font(Theme.font(13))
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 12)

            if shortcuts.isCustomized(action) {
                Button {
                    shortcuts.reset(action)
                    note = "\(action.title) restored to its default."
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help("Reset to default")
            }

            Button {
                recordingAction = action
                recording = true
            } label: {
                if isRecording {
                    Text("Press a key…")
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5)
                                .strokeBorder(Theme.accent, lineWidth: 1)
                        )
                } else {
                    KeyCapRow(bindings: shortcuts.bindings(for: action), emphasized: true)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3.5)
        .contentShape(Rectangle())
    }

    /// Structural keys, shown greyed so the panel documents everything that works rather than only
    /// the editable half -- but visibly not offered as rebindable, which would be a lie.
    private func fixedRow(keys: String, title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.font(13))
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 12)
            KeyCap(text: keys)
            Text("fixed")
                .font(Theme.font(10))
                .foregroundStyle(Theme.secondaryText.opacity(0.7))
        }
        .padding(.vertical, 3.5)
    }
}

struct GeneralSettings: View {
    @AppStorage("general.hideSleepingHours") private var hideSleepingHours = false
    @AppStorage("general.sleepStartHour") private var sleepStartHour = 22
    @AppStorage("general.sleepEndHour") private var sleepEndHour = 8
    @AppStorage("general.completionSound") private var completionSound = true
    @AppStorage("general.interfaceFont") private var interfaceFont = Theme.InterfaceFont.avenir.rawValue

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

            Section("Appearance") {
                Picker("Interface font", selection: $interfaceFont) {
                    ForEach(Theme.InterfaceFont.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("""
                    Avenir Next is rounder and lighter, but has a smaller x-height, so it reads a \
                    size down at the 10-13pt most of this interface uses. SF is drawn for that \
                    range and is usually crisper on screen.
                    """)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.secondaryText)
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

/// Disconnect / start fresh (#36). Wipes only Remit's own layer -- favourites, emoji, order,
/// filters, templates -- and never touches a single reminder, tag or section.
struct DataSettings: View {
    @EnvironmentObject private var metadataStore: MetadataStore
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remit layer")
                .font(Theme.font(13, .semibold))
            Text("""
                Favourites, project emoji, sidebar order, saved filters and templates are stored by \
                Remit, because Apple Reminders has nowhere to put them. Tasks, lists, tags and \
                sections always live in Reminders and are never stored here.
                """)
                .font(Theme.font(11))
                .foregroundStyle(.secondary)

            Button("Reset Remit Data...", role: .destructive) { confirming = true }

            Text("This deletes the Remit layer only. Every task and list stays in Apple Reminders.")
                .font(Theme.font(10))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
        .confirmationDialog("Reset all Remit data?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { metadataStore.resetAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Favourites, emoji, project order, filters and templates will be erased. Your Reminders tasks, lists, tags and sections are not affected.")
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
