import Foundation

/// Todoist-style P1-P4 priority, mapped onto EventKit's 0/1-4/5/6-9 priority scale.
///
/// EventKit's scale is finer-grained than Todoist's four buckets (any raw value 1-4 counts as
/// "high" in the Reminders app), so this mapping is lossy in one direction: setting `.p1` always
/// writes EKReminder.priority = 1, but reading back a reminder with priority 2, 3, or 4 (set by
/// some other app) also maps to `.p1`. That's an accepted approximation for v1 -- see ROADMAP.md.
enum Priority: Int, CaseIterable, Codable, Comparable, Identifiable {
    case p1 = 1
    case p2 = 5
    case p3 = 9
    case p4 = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .p1: return "Priority 1"
        case .p2: return "Priority 2"
        case .p3: return "Priority 3"
        case .p4: return "Priority 4"
        }
    }

    /// Lower is more urgent, matching Todoist's P1 (most urgent) -> P4 (least) ordering.
    private var urgencyRank: Int {
        switch self {
        case .p1: return 0
        case .p2: return 1
        case .p3: return 2
        case .p4: return 3
        }
    }

    static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.urgencyRank < rhs.urgencyRank
    }

    init(ekPriority: Int) {
        switch ekPriority {
        case 1...4: self = .p1
        case 5: self = .p2
        case 6...9: self = .p3
        default: self = .p4
        }
    }
}
