import SwiftUI

/// An Apple Reminders tag.
///
/// Tags are Reminders' own, not a Remit layer on top of it. They are read from Reminders' store
/// (RemindersNative) and written through ReminderKit (ReminderKitBridge), so a tag added in Remit is
/// the same tag in Reminders.app and on iPhone, and the other way round. EventKit still has no tags
/// API at all -- that is the only reason those two modules exist instead of going through
/// `EKReminder`.
///
/// A tag is just its name. Reminders stores no colour, folder or order for one, and Remit
/// deliberately invents none: anything kept only here would be invisible everywhere else, and the
/// two apps would stop agreeing about what a tag is.
struct ReminderTag: Identifiable, Hashable {
    let name: String
    var id: String { name }

    /// One quiet colour for every tag. There is no Reminders colour to mirror, and tag names
    /// already carry their own emoji.
    var color: Color { Self.chipColor }

    static let chipColor = Color(hex: "#6B7280")
}
