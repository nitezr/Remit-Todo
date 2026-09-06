import SwiftUI

/// Calendar layout with Day / 3 Days / Week / Month ranges.
///
/// Month renders as a grid; the shorter ranges render as day columns side by side, which is the
/// only way a single day is legible. Dropping a task on any day reschedules it in every range.
///
/// Undated tasks have no cell to live in, so they're surfaced in a strip below rather than silently
/// omitted -- a task you can't see is a task you'll miss.
struct CalendarView: View {
    let tasks: [RemitTask]
    @Binding var selectedTaskID: String?
    @Binding var range: CalendarRange
    var onReschedule: (RemitTask, Date) -> Void

    @State private var anchor = Calendar.current.startOfDay(for: Date())
    @AppStorage("general.hideSleepingHours") private var hideSleepingHours = false
    @AppStorage("general.sleepStartHour") private var sleepStartHour = 22
    @AppStorage("general.sleepEndHour") private var sleepEndHour = 8

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if range == .month {
                monthGridView
                if !undated.isEmpty {
                    Divider()
                    undatedStrip
                }
            } else {
                // The hour grid has its own All-day row, so the undated strip would duplicate it.
                CalendarHourGrid(
                    days: visibleDays,
                    tasks: tasks,
                    selectedTaskID: $selectedTaskID,
                    hideSleepingHours: hideSleepingHours,
                    sleepStartHour: sleepStartHour,
                    sleepEndHour: sleepEndHour,
                    onReschedule: onReschedule
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)

            Text(rangeTitle)
                .font(Theme.font(13, .semibold))
                .frame(minWidth: 170, alignment: .leading)

            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)

            Button("Today") { anchor = calendar.startOfDay(for: Date()) }
                .buttonStyle(.link)

            Spacer()

            if range != .month {
                Button {
                    hideSleepingHours.toggle()
                } label: {
                    Image(systemName: hideSleepingHours ? "moon.fill" : "moon")
                }
                .buttonStyle(.plain)
                .help(hideSleepingHours
                      ? "Showing waking hours only — click to show the full day"
                      : "Hide sleeping hours")
            }

            Picker("", selection: $range) {
                ForEach(CalendarRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.pageBackground)
    }

    private var rangeTitle: String {
        switch range {
        case .month:
            return anchor.formatted(.dateTime.month(.wide).year())
        case .day:
            return anchor.formatted(.dateTime.weekday(.wide).day().month(.wide))
        default:
            let days = visibleDays
            guard let first = days.first, let last = days.last else { return "" }
            return "\(TaskGrouping.shortDate(first)) – \(TaskGrouping.shortDate(last))"
        }
    }

    /// Paging moves by whatever is on screen, so Week steps a week and Day steps a day.
    private func shift(_ direction: Int) {
        switch range {
        case .month:
            anchor = calendar.startOfMonth(for: calendar.date(byAdding: .month, value: direction, to: anchor) ?? anchor)
        default:
            anchor = calendar.date(byAdding: .day, value: direction * range.dayCount, to: anchor) ?? anchor
        }
    }

    // MARK: - Day columns (Day / 3 Days / Week)

    private var visibleDays: [Date] {
        let start = range == .week ? calendar.startOfWeek(for: anchor) : anchor
        return (0..<max(1, range.dayCount)).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
    }

    // MARK: - Month grid

    private var monthGridView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(calendar.shortWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol.uppercased())
                        .font(Theme.font(10, .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)

            GeometryReader { proxy in
                let weeks = monthGrid
                VStack(spacing: 0) {
                    ForEach(weeks.indices, id: \.self) { index in
                        HStack(spacing: 0) {
                            ForEach(weeks[index], id: \.self) { day in
                                monthCell(day).frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: max(74, proxy.size.height / CGFloat(weeks.count)))
                    }
                }
            }
        }
    }

    private func monthCell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: anchor, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let dayTasks = tasks(on: day)

        return VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.day()))
                .font(Theme.font(11, isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Theme.accent : (inMonth ? Theme.primaryText : Theme.secondaryText))

            ForEach(dayTasks.prefix(3)) { task in
                chip(task, compact: true)
            }
            if dayTasks.count > 3 {
                Text("+\(dayTasks.count - 3) more")
                    .font(Theme.font(9))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(inMonth ? Color.clear : Theme.columnBackground.opacity(0.5))
        .overlay(Rectangle().stroke(Theme.separator, lineWidth: 0.5))
        .dropDestination(for: String.self) { ids, _ in
            drop(ids, on: day)
        }
    }

    /// Six weeks covering the month, padded to whole weeks.
    private var monthGrid: [[Date]] {
        let monthStart = calendar.startOfMonth(for: anchor)
        var cursor = calendar.startOfWeek(for: monthStart)
        var weeks: [[Date]] = []

        while weeks.count < 6 {
            let week = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: cursor) }
            weeks.append(week)
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
            if weeks.count >= 4,
               !calendar.isDate(cursor, equalTo: monthStart, toGranularity: .month) {
                break
            }
        }
        return weeks
    }

    // MARK: - Shared pieces

    private func chip(_ task: RemitTask, compact: Bool) -> some View {
        let isSelected = task.id == selectedTaskID
        return HStack(spacing: 4) {
            Circle()
                .fill(Theme.priority(task.priority))
                .frame(width: 5, height: 5)
            Text(task.title)
                .font(Theme.font(compact ? 10 : 11))
                .lineLimit(compact ? 1 : 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, compact ? 1 : 3)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.accent.opacity(isSelected ? 0.3 : 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Theme.accent, lineWidth: isSelected ? 1 : 0)
        )
        .contentShape(Rectangle())
        .draggable(task.id)
        .onTapGesture { selectedTaskID = task.id }
    }

    private func tasks(on day: Date) -> [RemitTask] {
        tasks.filter { task in
            guard let due = task.dueDate else { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }
    }

    private func drop(_ ids: [String], on day: Date) -> Bool {
        guard let id = ids.first, let task = tasks.first(where: { $0.id == id }) else { return false }
        onReschedule(task, calendar.startOfDay(for: day))
        return true
    }

    private var undated: [RemitTask] {
        tasks.filter { $0.dueDate == nil }
    }

    private var undatedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No date")
                .font(Theme.font(11, .semibold))
                .foregroundStyle(Theme.secondaryText)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(undated) { task in
                        chip(task, compact: true).frame(maxWidth: 180)
                    }
                }
            }
        }
        .padding(8)
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }

    func startOfWeek(for date: Date) -> Date {
        self.date(from: dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) ?? startOfDay(for: date)
    }
}
