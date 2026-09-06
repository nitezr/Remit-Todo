import Foundation

/// One view's display settings.
struct DisplayPreferences: Codable, Equatable {
    var layout: TaskLayout = .list
    var groupBy: TaskGroupBy = .default
    var sorting: TaskSorting = .smart
    var showsCompleted: Bool = false
    var deadline: DeadlineFilter = .all
    var priorityFilter: String = "all"
    var labelFilter: String = "all"
    var calendarRange: CalendarRange = .month
}

/// Display settings kept **per view**, not globally.
///
/// These were originally one shared set of AppStorage keys, which meant switching a project to
/// Board also switched Today, Upcoming, Inbox and every other project to Board. Todoist scopes
/// these per view and so does the Glaze build (`display-prefs.ts`): Board makes sense for one
/// project while Calendar makes sense for Upcoming, and grouping by Priority in one place should
/// not reorganise everywhere else.
@MainActor
final class DisplayPrefsStore: ObservableObject {
    @Published private var byView: [String: DisplayPreferences]

    private let defaultsKey = "display.preferences.byView"

    init() {
        if let raw = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: DisplayPreferences].self, from: raw) {
            byView = decoded
        } else {
            byView = [:]
        }
    }

    func preferences(for viewKey: String) -> DisplayPreferences {
        byView[viewKey] ?? DisplayPreferences()
    }

    func set(_ preferences: DisplayPreferences, for viewKey: String) {
        byView[viewKey] = preferences
        persist()
    }

    /// Resets just this view, leaving every other view's settings alone.
    func reset(_ viewKey: String) {
        byView[viewKey] = nil
        persist()
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(byView) else { return }
        UserDefaults.standard.set(encoded, forKey: defaultsKey)
    }
}

/// A stable per-view identity for the settings above. Project and label views key off their own
/// id so each gets its own settings; the fixed views use a constant.
extension SidebarSelection {
    var displayKey: String {
        switch self {
        case .inbox: return "inbox"
        case .today: return "today"
        case .upcoming: return "upcoming"
        case .filtersAndLabels: return "filtersAndLabels"
        case .label(let id): return "label.\(id)"
        case .filter(let id): return "filter.\(id)"
        case .project(let id): return "project.\(id)"
        }
    }
}
