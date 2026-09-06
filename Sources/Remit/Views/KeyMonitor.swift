import AppKit

/// App-level key handling for the task list.
///
/// SwiftUI's `.onKeyPress` was tried first and does not work here: `List` on macOS is backed by an
/// NSTableView that consumes key events before a `.focusable()` SwiftUI wrapper sees them, so plain
/// letter shortcuts never fired and arrow keys only did the table's own thing. A local NSEvent
/// monitor sits ahead of that entirely and works regardless of where SwiftUI thinks focus is.
///
/// The handler returns true to swallow the event. `isEditingText` is what keeps `j`/`e`/`t` from
/// being stolen while the quick-add field has the field editor -- without that check, typing a task
/// title would fire shortcuts on every keystroke.
final class KeyMonitor: ObservableObject {
    private var token: Any?

    func install(_ handler: @escaping (NSEvent) -> Bool) {
        remove()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event) ? nil : event
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }

    /// True while the settings panel is capturing a chord to bind. Ordering between two local
    /// event monitors is not guaranteed, so the task list checks this flag explicitly rather than
    /// trusting the recorder's monitor to run first -- otherwise recording `e` would complete a
    /// task behind the sheet.
    static var isRecording = false

    /// True while a text field owns the keyboard -- SwiftUI TextFields edit through an NSTextView
    /// field editor, so that's what shows up as first responder.
    static var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }
}
