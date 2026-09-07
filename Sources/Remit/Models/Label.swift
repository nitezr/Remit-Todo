import SwiftUI

/// A Todoist-style label.
///
/// This is a Remit-layer concept, not an Apple Reminders tag, and it has to be. Apple ships no
/// public API for Reminders tags on any surface: `EKReminder` exposes no tags property and isn't
/// even KVC-compliant for the key, and the Reminders AppleScript dictionary has no tag property
/// either. Writing "#bills" into a reminder's title was tested directly -- Reminders.app stores
/// and displays it as plain text, it does not promote it to a tag. So labels live here, in
/// MetadataStore, the same tier as sections and project nesting. The Glaze build reached the same
/// conclusion independently (`main/services/labels-service.ts`).
///
/// Consequence to keep in mind: labels do not sync to iPhone and are invisible in Reminders.app.
/// Deleting Remit's metadata file loses labels but never loses a task.
struct RemitLabel: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var color: LabelColor
    var order: Int
}

enum LabelColor: String, CaseIterable, Codable {
    case red, orange, yellow, green, blue, purple, magenta, gray
    // Added to cover the Todoist palette on import: without these, teal people-labels, a sky-blue
    // discuss label and taupe/charcoal all collapsed into "blue" and "gray" and stopped being
    // distinguishable at a glance, which is the entire job of a label colour.
    case teal, skyBlue, taupe, charcoal

    var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .magenta: return Color(red: 0.85, green: 0.2, blue: 0.6)
        case .gray: return .gray
        case .teal: return Color(hex: "#0F9B8E")
        case .skyBlue: return Color(hex: "#2196C4")
        case .taupe: return Color(hex: "#A08265")
        case .charcoal: return Color(hex: "#6E6E6E")
        }
    }

    /// Todoist's palette is larger than this one; anything without a direct match falls back to the
    /// nearest hue rather than to grey, so an imported label still reads as itself.
    static func fromTodoist(_ name: String) -> LabelColor {
        switch name {
        case "teal": return .teal
        case "sky_blue", "light_blue": return .skyBlue
        case "taupe": return .taupe
        case "charcoal", "grey", "gray": return .charcoal
        case "violet", "grape", "lavender": return .purple
        case "green", "olive_green", "lime_green", "mint_green": return .green
        case "orange", "salmon": return .orange
        case "yellow": return .yellow
        case "red", "berry_red": return .red
        case "magenta": return .magenta
        case "blue": return .blue
        default: return .gray
        }
    }
}
