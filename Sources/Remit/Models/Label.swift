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
        }
    }
}
