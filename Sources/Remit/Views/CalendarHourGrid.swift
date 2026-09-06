import SwiftUI

/// The timed grid behind Day / 3 Days / Week: an hour gutter, an All-day row, one column per day,
/// and a live "now" line.
///
/// Tasks with a due *time* are positioned against the hour axis; tasks due that day with no time
/// go in the All-day row rather than being pinned to midnight, which would bury them off the top
/// of the scroll. Dropping onto a column reschedules to that day.
///
/// The sleeping-hours toggle (#10) narrows the axis instead of filtering rows out, so a task at
/// 11PM isn't silently invisible -- the hours simply aren't drawn, and the task moves to All-day.
struct CalendarHourGrid: View {
    let days: [Date]
    let tasks: [RemitTask]
    @Binding var selectedTaskID: String?
    let hideSleepingHours: Bool
    let sleepStartHour: Int
    let sleepEndHour: Int
    var onReschedule: (RemitTask, Date) -> Void

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 48
    private let gutterWidth: CGFloat = 58

    /// The hours actually drawn. With sleeping hours hidden this is the waking window (default
    /// 8AM-10PM); otherwise the full day.
    private var hours: [Int] {
        guard hideSleepingHours else { return Array(0..<24) }
        if sleepEndHour < sleepStartHour {
            return Array(sleepEndHour..<sleepStartHour)   // 8..22 for a 22->8 sleep window
        }
        return Array(0..<24).filter { $0 < sleepStartHour || $0 >= sleepEndHour }
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            Divider()
            allDayRow
            Divider()

            // The grid must be the flexible child. Without an explicit height on the header and
            // all-day rows, those absorbed the leftover space and the hour grid collapsed to
            // nothing -- a tall empty band with the day names floating in the middle of it.
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    hourGutter
                    ForEach(days, id: \.self) { day in
                        dayColumn(day)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 1) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(Theme.font(11))
                        .foregroundStyle(calendar.isDateInToday(day) ? Theme.accent : Theme.secondaryText)
                    Text(day.formatted(.dateTime.day()))
                        .font(Theme.font(15, calendar.isDateInToday(day) ? .bold : .regular))
                        .foregroundStyle(calendar.isDateInToday(day) ? Theme.accent : Theme.primaryText)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 42)
    }

    /// Capped so a day with many undated tasks scrolls internally instead of pushing the hour
    /// grid off the bottom of the window.
    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("All-day")
                .font(Theme.font(11))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 4)

            ForEach(days, id: \.self) { day in
                // A frame constrains layout but does NOT clip: with enough all-day tasks the
                // chips drew straight past the row and over the header above it. Scrolling them
                // inside a clipped container is what actually bounds the row.
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(allDayTasks(on: day)) { task in
                            chip(task)
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 3)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .overlay(Rectangle().stroke(Theme.separator, lineWidth: 0.5))
                .dropDestination(for: String.self) { ids, _ in drop(ids, on: day) }
            }
        }
        .frame(height: allDayHeight)
        .clipped()
    }

    /// Grows with the busiest day, up to a cap, so a quiet week doesn't waste a fixed band and a
    /// busy one doesn't crowd out the hour grid.
    private var allDayHeight: CGFloat {
        let busiest = days.map { allDayTasks(on: $0).count }.max() ?? 0
        return min(96, max(30, CGFloat(busiest) * 24 + 8))
    }

    // MARK: - Grid body

    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(hours, id: \.self) { hour in
                Text(GeneralSettings.hourLabel(hour))
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: gutterWidth, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, 6)
                    // Nudged up so the label sits level with its gridline rather than below it.
                    .offset(y: -6)
            }
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(hours, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: hourHeight)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                        }
                }
            }

            ForEach(timedTasks(on: day)) { task in
                chip(task)
                    .padding(.horizontal, 3)
                    .offset(y: offset(for: task))
            }

            if let nowOffset, calendar.isDateInToday(day) {
                Rectangle()
                    .fill(Theme.overdue)
                    .frame(height: 1.5)
                    .offset(y: nowOffset)
            }
        }
        .frame(height: CGFloat(hours.count) * hourHeight, alignment: .top)
        .background(calendar.isDateInToday(day) ? Theme.accent.opacity(0.04) : Color.clear)
        .overlay(Rectangle().stroke(Theme.separator, lineWidth: 0.5))
        .dropDestination(for: String.self) { ids, _ in drop(ids, on: day) }
    }

    // MARK: - Positioning

    /// Vertical offset of a time within the drawn hours. Returns nil when that hour isn't drawn.
    private func offset(forHour hour: Int, minute: Int) -> CGFloat? {
        guard let index = hours.firstIndex(of: hour) else { return nil }
        return CGFloat(index) * hourHeight + (CGFloat(minute) / 60) * hourHeight
    }

    private func offset(for task: RemitTask) -> CGFloat {
        guard let due = task.dueDate else { return 0 }
        let hour = calendar.component(.hour, from: due)
        let minute = calendar.component(.minute, from: due)
        return offset(forHour: hour, minute: minute) ?? 0
    }

    private var nowOffset: CGFloat? {
        let now = Date()
        return offset(
            forHour: calendar.component(.hour, from: now),
            minute: calendar.component(.minute, from: now)
        )
    }

    // MARK: - Data

    private func tasks(on day: Date) -> [RemitTask] {
        tasks.filter { task in
            guard let due = task.dueDate else { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }
    }

    /// Timed tasks whose hour is currently drawn. Anything outside the window falls through to the
    /// All-day row instead of vanishing.
    private func timedTasks(on day: Date) -> [RemitTask] {
        tasks(on: day).filter { task in
            guard task.hasDueTime, let due = task.dueDate else { return false }
            return hours.contains(calendar.component(.hour, from: due))
        }
    }

    private func allDayTasks(on day: Date) -> [RemitTask] {
        let timed = Set(timedTasks(on: day).map(\.id))
        return tasks(on: day).filter { !timed.contains($0.id) }
    }

    private func chip(_ task: RemitTask) -> some View {
        let isSelected = task.id == selectedTaskID
        return HStack(spacing: 4) {
            Circle()
                .fill(Theme.priority(task.priority))
                .frame(width: 5, height: 5)
            Text(task.title)
                .font(Theme.font(12))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.accent.opacity(isSelected ? 0.3 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Theme.accent, lineWidth: isSelected ? 1 : 0)
        )
        .contentShape(Rectangle())
        .draggable(task.id)
        .onTapGesture { selectedTaskID = task.id }
    }

    private func drop(_ ids: [String], on day: Date) -> Bool {
        guard let id = ids.first, let task = tasks.first(where: { $0.id == id }) else { return false }
        onReschedule(task, calendar.startOfDay(for: day))
        return true
    }
}
