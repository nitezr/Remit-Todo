import XCTest
@testable import Remit

/// W on a Saturday used to land on that same Saturday, which looked like the key setting Today.
final class ScheduleTargetTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A mid-afternoon moment `offset` days after Monday 7 September 2026.
    private func day(_ offset: Int) -> Date {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 15))!
        return calendar.date(byAdding: .day, value: offset, to: monday)!
    }

    private func daysAhead(of target: ScheduleTarget, from now: Date) -> Int? {
        guard let date = target.resolvedDate(from: now, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day
    }

    func testWeekendFromAWeekdayIsTheComingSaturday() {
        for offset in 0...4 {  // Monday to Friday
            let now = day(offset)
            let target = ScheduleTarget.weekend.resolvedDate(from: now, calendar: calendar)!
            XCTAssertEqual(calendar.component(.weekday, from: target), 7, "day \(offset) should reach a Saturday")
            XCTAssertEqual(daysAhead(of: .weekend, from: now), 5 - offset)
        }
    }

    func testWeekendOnASaturdayIsNextSaturdayNotToday() {
        XCTAssertEqual(daysAhead(of: .weekend, from: day(5)), 7)
    }

    func testWeekendOnASundayIsTheSaturdayAhead() {
        XCTAssertEqual(daysAhead(of: .weekend, from: day(6)), 6)
    }

    func testOtherTargets() {
        let now = day(2)
        XCTAssertEqual(daysAhead(of: .today, from: now), 0)
        XCTAssertEqual(ScheduleTarget.today.resolvedDate(from: now, calendar: calendar), calendar.startOfDay(for: now))
        XCTAssertEqual(daysAhead(of: .tomorrow, from: now), 1)
        XCTAssertEqual(daysAhead(of: .nextWeek, from: now), 7)
        XCTAssertNil(ScheduleTarget.none.resolvedDate(from: now, calendar: calendar))
    }
}
