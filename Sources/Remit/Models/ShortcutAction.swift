import AppKit

/// One remappable key combination.
///
/// A binding is either a character (`j`, `1`) or a virtual key code (Return, Delete), plus the
/// modifier set. Modifiers are stored as `NSEvent.ModifierFlags` raw values so a recorded chord
/// round-trips exactly, and they are what disambiguates `t` from `⇧T` — comparing the character
/// case-insensitively is safe precisely because shift is carried in `modifiers`.
struct KeyBinding: Codable, Hashable, Identifiable {
    var character: String?
    var keyCode: UInt16?
    var modifiers: UInt

    var id: String { display }

    init(_ character: String, modifiers: NSEvent.ModifierFlags = []) {
        self.character = character
        self.keyCode = nil
        self.modifiers = modifiers.rawValue
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.character = nil
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
    }

    /// Everything macOS puts on an event that the user did not deliberately press. Arrow keys carry
    /// `.function` and `.numericPad`, and caps lock is a state rather than a chord — leaving any of
    /// them in made every arrow fail a "no modifiers" comparison.
    static func normalize(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
    }

    init?(event: NSEvent) {
        let mods = Self.normalize(event.modifierFlags)
        self.modifiers = mods.rawValue
        if let special = Self.specialKeyNames[event.keyCode] {
            _ = special
            self.keyCode = event.keyCode
            self.character = nil
            return
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              chars.count == 1,
              chars != " " else { return nil }
        self.character = chars
        self.keyCode = nil
    }

    func matches(_ event: NSEvent) -> Bool {
        guard Self.normalize(event.modifierFlags).rawValue == modifiers else { return false }
        if let keyCode { return event.keyCode == keyCode }
        guard let character else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == character
    }

    /// Rendered the way macOS writes shortcuts: modifier glyphs in Apple's canonical order, then
    /// the key.
    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        if let keyCode {
            out += Self.specialKeyNames[keyCode] ?? "key \(keyCode)"
        } else if let character {
            out += character.uppercased()
        }
        return out
    }

    static let specialKeyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "space", 51: "⌫", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// Every remappable action.
///
/// Arrow keys and Return are deliberately **not** here. They are structural navigation rather than
/// shortcuts -- rebinding "move down" off the down arrow would leave the list unnavigable -- so
/// they stay hard-wired and are documented as fixed rather than offered as editable rows that
/// pretend to more flexibility than exists.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case nextTask, previousTask
    case commandPalette, shortcutsPanel
    case completeTask, openDetail, quickAdd, editLabels
    case priority1, priority2, priority3, priority4
    case scheduleToday, scheduleTomorrow, scheduleWeekend, scheduleNextWeek, scheduleClear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextTask: return "Next task"
        case .previousTask: return "Previous task"
        case .commandPalette: return "Command palette / search"
        case .shortcutsPanel: return "Keyboard shortcuts panel"
        case .completeTask: return "Complete task"
        case .openDetail: return "Open task detail"
        case .quickAdd: return "Quick add"
        case .editLabels: return "Edit tags"
        case .priority1: return "Priority 1"
        case .priority2: return "Priority 2"
        case .priority3: return "Priority 3"
        case .priority4: return "Priority 4"
        case .scheduleToday: return "Today"
        case .scheduleTomorrow: return "Tomorrow"
        case .scheduleWeekend: return "This weekend"
        case .scheduleNextWeek: return "Next week"
        case .scheduleClear: return "Remove due date"
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case navigation = "Navigation"
        case tasks = "Tasks"
        case schedule = "Schedule"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .nextTask, .previousTask, .commandPalette, .shortcutsPanel: return .navigation
        case .completeTask, .openDetail, .quickAdd, .editLabels,
             .priority1, .priority2, .priority3, .priority4: return .tasks
        case .scheduleToday, .scheduleTomorrow, .scheduleWeekend,
             .scheduleNextWeek, .scheduleClear: return .schedule
        }
    }

    /// Defaults match the Glaze build's `renderer/lib/shortcut-config.ts` so muscle memory carries
    /// over. Several actions ship two keys; `u`/`m` for tomorrow and `q`/`a` for quick add both
    /// existed there, and dropping one to make remapping simpler would be a regression.
    var defaultBindings: [KeyBinding] {
        switch self {
        case .nextTask: return [KeyBinding("j")]
        case .previousTask: return [KeyBinding("k")]
        case .commandPalette: return [KeyBinding("/")]
        case .shortcutsPanel: return [KeyBinding("?", modifiers: .shift)]
        case .completeTask: return [KeyBinding("e")]
        case .openDetail: return [KeyBinding("i")]
        case .quickAdd: return [KeyBinding("q"), KeyBinding("a")]
        case .editLabels: return [KeyBinding("l")]
        case .priority1: return [KeyBinding("1")]
        case .priority2: return [KeyBinding("2")]
        case .priority3: return [KeyBinding("3")]
        case .priority4: return [KeyBinding("4")]
        case .scheduleToday: return [KeyBinding("t")]
        case .scheduleTomorrow: return [KeyBinding("u"), KeyBinding("m")]
        case .scheduleWeekend: return [KeyBinding("w")]
        case .scheduleNextWeek: return [KeyBinding("n")]
        case .scheduleClear: return [KeyBinding("0"), KeyBinding("t", modifiers: .shift)]
        }
    }

    /// Shown in the reference panel alongside the remappable rows, so the panel documents
    /// everything that works rather than only the parts that happen to be editable.
    static let fixedBindings: [(group: Group, keys: String, title: String)] = [
        (.navigation, "↓ ↑", "Next / previous task"),
        (.navigation, "← →", "Move between board columns"),
        (.navigation, "⌘K", "Command palette"),
        (.navigation, "⌘S", "Toggle sidebar"),
        (.tasks, "↩", "Open task detail"),
        (.tasks, "⌘⌫", "Delete task"),
        (.tasks, "⌘Z", "Undo last change"),
    ]
}
