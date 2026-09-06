import AppKit
import SwiftUI

/// A key rendered as a physical cap rather than plain monospace text.
///
/// The reference list previously set bindings in a monospaced font and left them to run together
/// ("⌘K  or  /"), which reads as prose about keys instead of as keys. A cap gives each chord an
/// edge, so a row scans as "this key does this" at a glance.
struct KeyCap: View {
    let text: String
    var emphasized = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(emphasized ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .frame(minWidth: 22)
            .background(
                RoundedRectangle(cornerRadius: 4.5)
                    .fill(Theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5)
                            .strokeBorder(Theme.separator, lineWidth: 1)
                    )
            )
            .fixedSize()
    }
}

/// A row of caps, with "or" between alternates so two bindings don't read as a chord.
struct KeyCapRow: View {
    let bindings: [KeyBinding]
    var emphasized = false

    var body: some View {
        HStack(spacing: 4) {
            if bindings.isEmpty {
                Text("unassigned")
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.overdue)
            } else {
                ForEach(Array(bindings.enumerated()), id: \.offset) { index, binding in
                    if index > 0 {
                        Text("or")
                            .font(Theme.font(10))
                            .foregroundStyle(Theme.secondaryText.opacity(0.7))
                    }
                    KeyCap(text: binding.display, emphasized: emphasized)
                }
            }
        }
    }
}

/// Captures the next chord the user presses and hands it back.
///
/// It installs its own local event monitor and flips `KeyMonitor.isRecording`, which the task
/// list's monitor checks and bails on. Ordering between two local monitors is not something to
/// rely on, so an explicit flag is what actually guarantees `e` gets recorded here instead of
/// completing a task behind the sheet.
struct ShortcutRecorder: View {
    @Binding var recording: Bool
    let onCapture: (KeyBinding) -> Void

    @State private var monitor: Any?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: recording) { _, isRecording in
                isRecording ? start() : stop()
            }
            .onDisappear(perform: stop)
    }

    private func start() {
        stop()
        KeyMonitor.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels rather than binding itself; it is the universal "get me out".
            if event.keyCode == 53 {
                recording = false
                return nil
            }
            // A bare modifier press is the user still assembling a chord, not a finished one.
            guard let binding = KeyBinding(event: event) else { return nil }
            onCapture(binding)
            recording = false
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        KeyMonitor.isRecording = false
    }
}
