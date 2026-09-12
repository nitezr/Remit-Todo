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

/// Where Remit's data lives, and a way to start Remit's own settings over.
///
/// The old tab explained a "Remit layer" of labels and sections that no longer exists -- those are
/// Reminders' own now -- so it stopped making sense. This says plainly what Reminders holds, what
/// Remit saves on this Mac, and whether tags and sections are readable.
struct DataSettings: View {
    @EnvironmentObject private var metadataStore: MetadataStore
    @EnvironmentObject private var remindersService: RemindersService
    @State private var confirming = false

    var body: some View {
        Form {
            Section("In Apple Reminders") {
                item(
                    "checklist",
                    "Tasks, lists, tags, sections and list groups",
                    "Synced by iCloud to all your devices, as always. Remit reads and changes them in place and keeps no copy."
                )
                LabeledContent("Tags and sections") {
                    switch remindersService.nativeStatus {
                    case .available:
                        Label("Readable", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.today)
                    case .needsFullDiskAccess:
                        Button("Needs Full Disk Access…") {
                            NSWorkspace.shared.open(NativeMetadataStatus.fullDiskAccessSettingsURL)
                        }
                    case .unavailable:
                        Text("Unavailable").foregroundStyle(Theme.overdue)
                    case .unknown:
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Saved by Remit on this Mac") {
                item(
                    "line.3.horizontal.decrease.circle",
                    "Saved filters, favourites, list emoji, sidebar order and templates",
                    "Reminders has nowhere to keep these, so Remit saves them in its own file, with a backup."
                )
                item(
                    "slider.horizontal.3",
                    "Display settings, keyboard shortcuts and preferences",
                    "Saved in Remit's preferences."
                )
                Button("Show Settings File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([metadataStore.fileLocation])
                }
            }

            Section {
                Button("Reset Remit's Settings…", role: .destructive) { confirming = true }
            } footer: {
                Text("Clears saved filters, favourites, list emoji, sidebar order and templates. Your reminders, tags and sections are not affected.")
                    .font(Theme.font(11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset Remit's settings?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { metadataStore.resetAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saved filters, favourites, list emoji, sidebar order and templates will be erased. Your reminders, tags and sections are not affected.")
        }
    }

    private func item(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(13))
                Text(detail)
                    .font(Theme.font(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
