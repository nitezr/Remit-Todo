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

    /// Which family the interface renders in.
    ///
    /// Avenir Next was chosen for Todoist's look (#12), but its x-height is about 11% smaller than
    /// the system face -- 6.08pt against 6.84pt at size 13 -- so it reads a size down and looks
    /// thin at the 10-13pt this UI mostly lives in. SF is drawn for exactly that range. Rather
    /// than overturn a deliberate design decision, both are offered and the difference is visible
    /// side by side in Settings.
    enum InterfaceFont: String, CaseIterable, Identifiable {
        case avenir, system
        var id: String { rawValue }
        var label: String {
            switch self {
            case .avenir: return "Avenir Next"
            case .system: return "System (SF)"
            }
        }
    }

    static var family: InterfaceFont {
        InterfaceFont(rawValue: UserDefaults.standard.string(forKey: "general.interfaceFont") ?? "")
            ?? .avenir
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch family {
        case .avenir:
            // The smaller x-height is compensated below 14pt, where it costs legibility rather
            // than character. Whole points only: a fractional size lands off the pixel grid and
            // renders softer, which is most of why small text looked muddy.
            return .custom("Avenir Next", size: size < 14 ? size + 1 : size).weight(weight)
        case .system:
            return .system(size: size, weight: weight)
        }
    }

    /// Avenir Next has a smaller x-height than the system face, so matching Todoist's *apparent*
    /// size means setting a point size a little above what SF would need. These were raised after
    /// the first pass read too small on screen.
    static var taskTitle: Font { font(15) }
    static var taskNotes: Font { font(13) }
    static var taskMeta: Font { font(12) }
    static var sectionHeader: Font { font(14, .semibold) }
    static var sidebarRow: Font { font(14) }
    static var sidebarHeader: Font { font(12, .semibold) }
    static var cardTitle: Font { font(15) }
    static var viewTitle: Font { font(21, .bold) }

    // MARK: - Colour

    /// Todoist's signature red, used for P1 and the active accent.
    static let accent = Color(light: Color(hex: "#DC4C3E"), dark: Color(hex: "#E8695D"))

    // Three levels, deepest to lightest: sidebar, page, card. The page was #FFFFFF and the card
    // was also #FFFFFF, so a card had *no* contrast against what it sat on -- only its 1px border
    // separated the two, which is why cards read as flat outlines instead of surfaces, and why a
    // full window of it is harsh to look at. An off-white page is what lets a white card lift, and
    // it is the single biggest reason the reference looks calmer at the same brightness.
    static let pageBackground = Color(light: Color(hex: "#FAF9F7"), dark: Color(hex: "#1F1F1F"))
    static let sidebarBackground = Color(light: Color(hex: "#F3F1EE"), dark: Color(hex: "#282828"))
    static let cardBackground = Color(light: Color(hex: "#FFFFFF"), dark: Color(hex: "#2C2C2C"))
    static let columnBackground = Color(light: Color(hex: "#F0EEEB"), dark: Color(hex: "#252525"))
    static let separator = Color(light: Color(hex: "#E6E3DF"), dark: Color(hex: "#3A3A3A"))

    /// The lift under a card. Deliberately tiny: the elevation is doing the separating, so the
    /// border can stay almost invisible instead of drawing the shape by itself.
    static let cardShadow = Color(light: Color.black.opacity(0.055), dark: Color.black.opacity(0.28))

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
