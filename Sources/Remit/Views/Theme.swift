import SwiftUI

/// Typography and colour, in one place.
///
/// Prompt #12 called typography "what makes Todoist attractive" and asked for it to be treated as
/// a first-class decision rather than a default. Todoist ships a geometric humanist sans; the
/// nearest thing on macOS without bundling a font file is **Avenir Next**, falling back to the
/// system face. Sizes and weights below mirror Todoist's own scale rather than SwiftUI defaults.
///
/// Prompt #24 asked for a dark theme matching Todoist's, not generic system dark: Todoist's dark
/// is a warm near-black (#1F1F1F surfaces on #282828 chrome) rather than macOS's blue-tinted
/// graphite, with muted rather than saturated accents.
enum Theme {

    // MARK: - Type scale

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Avenir Next", size: size).weight(weight)
    }

    /// Avenir Next has a smaller x-height than the system face, so matching Todoist's *apparent*
    /// size means setting a point size a little above what SF would need. These were raised after
    /// the first pass read too small on screen.
    static var taskTitle: Font { font(15) }
    static var taskNotes: Font { font(12.5) }
    static var taskMeta: Font { font(11.5) }
    static var sectionHeader: Font { font(14, .semibold) }
    static var sidebarRow: Font { font(14) }
    static var sidebarHeader: Font { font(12, .semibold) }
    static var cardTitle: Font { font(14) }
    static var viewTitle: Font { font(21, .bold) }

    // MARK: - Colour

    /// Todoist's signature red, used for P1 and the active accent.
    static let accent = Color(light: Color(hex: "#DC4C3E"), dark: Color(hex: "#E8695D"))

    static let pageBackground = Color(light: Color(hex: "#FFFFFF"), dark: Color(hex: "#1F1F1F"))
    static let sidebarBackground = Color(light: Color(hex: "#FAFAFA"), dark: Color(hex: "#282828"))
    static let cardBackground = Color(light: Color(hex: "#FFFFFF"), dark: Color(hex: "#2C2C2C"))
    static let columnBackground = Color(light: Color(hex: "#F5F5F5"), dark: Color(hex: "#252525"))
    static let separator = Color(light: Color(hex: "#EBEBEB"), dark: Color(hex: "#3A3A3A"))

    static let primaryText = Color(light: Color(hex: "#202020"), dark: Color(hex: "#E3E3E3"))
    static let secondaryText = Color(light: Color(hex: "#808080"), dark: Color(hex: "#9A9A9A"))

    static let overdue = Color(light: Color(hex: "#DC4C3E"), dark: Color(hex: "#E8695D"))
    static let today = Color(light: Color(hex: "#058527"), dark: Color(hex: "#4CAF63"))

    static func priority(_ priority: Priority) -> Color {
        switch priority {
        case .p1: return Color(light: Color(hex: "#DC4C3E"), dark: Color(hex: "#E8695D"))
        case .p2: return Color(light: Color(hex: "#EB8909"), dark: Color(hex: "#F0A03C"))
        case .p3: return Color(light: Color(hex: "#246FE0"), dark: Color(hex: "#5B93E8"))
        case .p4: return Color(light: Color(hex: "#999999"), dark: Color(hex: "#8A8A8A"))
        }
    }
}

private extension Color {
    /// Resolves per appearance so a single token works in both themes without a `@Environment`
    /// read at every call site.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

extension Character {
    /// True for pictographic characters, used to decide whether a Reminders list name already
    /// starts with its own icon. Plain digits carry `isEmoji` in Foundation's own check, so the
    /// presence of a variation selector or a genuinely pictographic scalar is required here.
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation
            || (scalar.properties.isEmoji && unicodeScalars.count > 1)
    }
}
