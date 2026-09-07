import Foundation

/// Natural-language quick-add parsing: `Pay rent tomorrow at 5pm p1 #Home @bills`.
///
/// Ported from the Glaze build's `renderer/lib/quick-add-parser.ts`. The extraction *order* in
/// `parse` is load-bearing and matches that file deliberately:
///
/// 1. `#project` and `@label` first, so their tokens can't be mistaken for words in the title.
/// 2. Priority before dates, so `p1` is never read as a number in a time.
/// 3. **Recurrence before dates** -- otherwise `every monday` gets consumed as a plain weekday
///    due date and the task silently isn't recurring. This is the one ordering constraint the
///    original file calls out in a comment; don't reorder these two.
/// 4. Time before date, so `at 5pm` is gone before weekday matching runs.
///
/// If stripping every token leaves an empty title, the whole original string is kept as the title
/// instead -- typing just `tomorrow` should give you a task called "tomorrow", not a blank one.
enum QuickAddParser {
    static func parse(
        _ input: String,
        projects: [RemitProject],
        labels: [String] = []
    ) -> QuickAddResult {
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)

        let (afterProject, projectID) = extractProject(original, projects: projects)
        let (afterLabels, matchedLabels, newLabels) = extractLabels(afterProject, labels: labels)
        let (afterPriority, priority) = extractPriority(afterLabels)
        let (afterRecurrence, recurrence, impliedDue) = extractRecurrence(afterPriority)
        let (afterTime, dueTime) = extractTime(afterRecurrence)
        let (afterDate, dueDate) = extractDueDate(afterTime)

        let title = afterDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return QuickAddResult(title: original)
        }

        // Recurrence and times both need a day to anchor to; default to today, like Todoist.
        var resolvedDue = dueDate ?? impliedDue
        if resolvedDue == nil, recurrence != nil || dueTime != nil {
            resolvedDue = Calendar.current.startOfDay(for: Date())
        }

        return QuickAddResult(
            title: title,
            dueDate: resolvedDue,
            dueTime: dueTime,
            priority: priority,
            projectID: projectID,
            recurrence: recurrence,
            labelNames: matchedLabels,
            newLabelNames: newLabels
        )
    }

    // MARK: - Component extraction

    private static let weekdays = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"
    ]

    private static func extractProject(
        _ text: String,
        projects: [RemitProject]
    ) -> (String, String?) {
        guard let match = text.firstMatch(#"#(\S+)"#), let name = match.group(1)?.lowercased() else {
            return (text, nil)
        }
        // Compared on a normalised form: names here carry leading emoji and spaces ("🤝 Acme"),
        // and the suggestion list writes the token with spaces stripped ("#🤝Acme"), so neither an
        // equality nor a prefix test on the raw title could ever match. Getting this wrong is
        // quiet and expensive -- the task lands in the default list instead of the one you named.
        let needle = normalizeName(name)
        // Exact first, then prefix, so `#Home` cannot silently pick "Homework".
        let found = projects.first { normalizeName($0.title) == needle }
            ?? projects.first { normalizeName($0.title).hasPrefix(needle) }
            ?? projects.first { normalizeName($0.title).contains(needle) }
        guard let found else { return (text, nil) }
        return (text.strippingMatch(match), found.id)
    }

    /// Resolves every `@label` token against the known label names, exact match then prefix.
    ///
    /// Tokens that match nothing are returned separately rather than discarded: the token is always
    /// stripped from the title (a typo'd `@foo` shouldn't linger there), but the caller decides
    /// whether an unrecognised name becomes a new label. The Glaze build dropped these silently,
    /// which only works because it has a label-management UI to create them in first.
    private static func extractLabels(
        _ text: String,
        labels: [String]
    ) -> (String, [String], [String]) {
        var remaining = text
        var matched: [String] = []
        var unmatched: [String] = []
        while let match = remaining.firstMatch(#"(^|\s)@(\S+)"#) {
            if let token = match.group(2) {
                let needle = normalizeLabel(token)
                let hit = labels.first { normalizeLabel($0) == needle }
                    ?? labels.first { normalizeLabel($0).hasPrefix(needle) }
                if let hit {
                    if !matched.contains(hit) { matched.append(hit) }
                } else if !unmatched.contains(token) {
                    unmatched.append(token)
                }
            }
            remaining = remaining.strippingMatch(match)
        }
        return (remaining, matched, unmatched)
    }

    private static func normalizeLabel(_ value: String) -> String {
        normalizeName(value)
    }

    /// Lowercased, with spaces removed and any leading emoji or punctuation dropped, so "🤝 Acme",
    /// "#🤝Acme" and "acme" all reduce to the same thing.
    static func normalizeName(_ value: String) -> String {
        var text = value.lowercased().replacingOccurrences(of: " ", with: "")
        while let first = text.first, !first.isLetter, !first.isNumber {
            text.removeFirst()
        }
        return text
    }

    private static func extractPriority(_ text: String) -> (String, Priority?) {
        guard let match = text.firstMatch(#"\bp([1-4])\b"#),
              let digit = match.group(1),
              let level = Int(digit) else {
            return (text, nil)
        }
        let priority: Priority = [.p1, .p2, .p3, .p4][level - 1]
        return (text.strippingMatch(match), priority)
    }

    /// Returns the recurrence plus, for `every <weekday>`, the day the series should be anchored
    /// on -- Todoist starts the series at the next matching weekday rather than today.
    private static func extractRecurrence(
        _ text: String
    ) -> (String, QuickAddRecurrence?, Date?) {
        if let match = text.firstMatch(#"\bevery weekday\b"#) {
            let weekdayRule = QuickAddRecurrence(frequency: .weekly, daysOfWeek: [2, 3, 4, 5, 6])
            return (text.strippingMatch(match), weekdayRule, nil)
        }

        if let match = text.firstMatch(#"\bevery (\d+) (day|week|month|year)s?\b"#),
           let count = match.group(1).flatMap(Int.init), count >= 1,
           let unit = match.group(2).flatMap({ QuickAddRecurrence.Frequency(noun: $0) }) {
            let rule = QuickAddRecurrence(frequency: unit, interval: count)
            return (text.strippingMatch(match), rule, nil)
        }

        if let match = text.firstMatch(#"\bevery (day|week|month|year)\b"#),
           let unit = match.group(1).flatMap({ QuickAddRecurrence.Frequency(noun: $0) }) {
            return (text.strippingMatch(match), QuickAddRecurrence(frequency: unit), nil)
        }

        if let match = text.firstMatch(#"\bevery (\#(weekdayPattern))\b"#),
           let index = match.group(1).flatMap(weekdayIndex) {
            let rule = QuickAddRecurrence(frequency: .weekly, daysOfWeek: [index + 1])
            let anchor = nextWeekday(from: Date(), to: index, forceNextWeek: false)
            return (text.strippingMatch(match), rule, anchor)
        }

        if let match = text.firstMatch(#"\b(daily|weekly|monthly|yearly)\b"#),
           let unit = match.group(1).flatMap({ QuickAddRecurrence.Frequency(adverb: $0) }) {
            return (text.strippingMatch(match), QuickAddRecurrence(frequency: unit), nil)
        }

        return (text, nil, nil)
    }

    /// `at 5pm`, `at 17:30`, and bare `5pm`. am/pm is required without a leading "at" so that
    /// plain numbers in a title (`buy 2 apples`) are never eaten as a time.
    private static func extractTime(_ text: String) -> (String, DateComponents?) {
        let match = text.firstMatch(#"\bat (\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#)
            ?? text.firstMatch(#"\b(\d{1,2})(?::(\d{2}))?(am|pm)\b"#)
        guard let match,
              let hourRaw = match.group(1).flatMap(Int.init) else { return (text, nil) }
        let minute = match.group(2).flatMap(Int.init) ?? 0
        guard let time = to24Hour(hourRaw, minute: minute, period: match.group(3)?.lowercased()) else {
            return (text, nil)
        }
        return (text.strippingMatch(match), time)
    }

    private static func to24Hour(_ hourRaw: Int, minute: Int, period: String?) -> DateComponents? {
        guard minute <= 59 else { return nil }
        var hour = hourRaw
        if let period {
            guard (1...12).contains(hour) else { return nil }
            if period == "pm", hour != 12 { hour += 12 }
            if period == "am", hour == 12 { hour = 0 }
        } else if hour > 23 {
            return nil
        }
        return DateComponents(hour: hour, minute: minute)
    }

    private static func extractDueDate(_ text: String) -> (String, Date?) {
        let now = Date()

        if let match = text.firstMatch(#"\bnext week\b"#) {
            return (text.strippingMatch(match), startOfDay(addingDays: 7, to: now))
        }
        if let match = text.firstMatch(#"\bnext (\#(weekdayPattern))\b"#),
           let index = match.group(1).flatMap(weekdayIndex) {
            return (text.strippingMatch(match), nextWeekday(from: now, to: index, forceNextWeek: true))
        }
        if let match = text.firstMatch(#"\btomorrow\b|\btmrw\b"#) {
            return (text.strippingMatch(match), startOfDay(addingDays: 1, to: now))
        }
        if let match = text.firstMatch(#"\btoday\b"#) {
            return (text.strippingMatch(match), startOfDay(addingDays: 0, to: now))
        }
        if let match = text.firstMatch(#"\b(\#(weekdayPattern))\b"#),
           let index = match.group(1).flatMap(weekdayIndex) {
            return (text.strippingMatch(match), nextWeekday(from: now, to: index, forceNextWeek: false))
        }
        return (text, nil)
    }

    // MARK: - Date helpers

    private static var weekdayPattern: String { weekdays.joined(separator: "|") }

    private static func weekdayIndex(_ name: String) -> Int? {
        weekdays.firstIndex(of: name.lowercased())
    }

    private static func startOfDay(addingDays days: Int, to date: Date) -> Date {
        let calendar = Calendar.current
        let shifted = calendar.date(byAdding: .day, value: days, to: date) ?? date
        return calendar.startOfDay(for: shifted)
    }

    /// `targetIndex` is 0-based Sunday-first, matching the `weekdays` array. `forceNextWeek`
    /// distinguishes `next monday` (always a week out when today is Monday) from a bare `monday`
    /// (which means today).
    private static func nextWeekday(from base: Date, to targetIndex: Int, forceNextWeek: Bool) -> Date {
        let baseIndex = Calendar.current.component(.weekday, from: base) - 1
        var diff = (targetIndex - baseIndex + 7) % 7
        if diff == 0, forceNextWeek { diff = 7 }
        return startOfDay(addingDays: diff, to: base)
    }
}

// MARK: - Result types

struct QuickAddResult {
    var title: String
    /// Start-of-day. `dueTime` carries the time component separately so callers can tell
    /// "due Tuesday" apart from "due Tuesday at 09:00".
    var dueDate: Date?
    var dueTime: DateComponents?
    var priority: Priority?
    var projectID: String?
    var recurrence: QuickAddRecurrence?
    /// Existing label names matched from `@token`s.
    var labelNames: [String] = []
    /// `@token`s that matched no existing label. Stripped from the title either way.
    var newLabelNames: [String] = []
}

struct QuickAddRecurrence: Equatable {
    enum Frequency: Equatable {
        case daily, weekly, monthly, yearly

        init?(noun: String) {
            switch noun.lowercased() {
            case "day": self = .daily
            case "week": self = .weekly
            case "month": self = .monthly
            case "year": self = .yearly
            default: return nil
            }
        }

        init?(adverb: String) {
            switch adverb.lowercased() {
            case "daily": self = .daily
            case "weekly": self = .weekly
            case "monthly": self = .monthly
            case "yearly": self = .yearly
            default: return nil
            }
        }
    }

    var frequency: Frequency
    var interval: Int = 1
    /// 1-based, Sunday = 1 -- matches both EventKit's `EKWeekday` and the Glaze build's encoding.
    var daysOfWeek: [Int]?
}

// MARK: - Regex convenience

/// Minimal wrapper so the extraction functions above read like the TypeScript original.
private struct RegexMatch {
    let range: Range<String.Index>
    private let groups: [String?]

    init(range: Range<String.Index>, groups: [String?]) {
        self.range = range
        self.groups = groups
    }

    func group(_ index: Int) -> String? {
        index < groups.count ? groups[index] : nil
    }
}

private extension String {
    func firstMatch(_ pattern: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let full = Range(match.range, in: self) else {
            return nil
        }
        let groups = (0..<match.numberOfRanges).map { index -> String? in
            guard let range = Range(match.range(at: index), in: self) else { return nil }
            return String(self[range])
        }
        return RegexMatch(range: full, groups: groups)
    }

    /// Removes the matched span and collapses the whitespace it leaves behind.
    func strippingMatch(_ match: RegexMatch) -> String {
        replacingCharacters(in: match.range, with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
