import AnokhaCore
import Foundation
import XCTest

final class ScheduleTests: XCTestCase {
    func testPlainLanguageSummaries() {
        XCTAssertEqual(JobSchedule.hourly(minute: 5).summary, "Hourly at :05")
        XCTAssertEqual(JobSchedule.daily(hour: 9, minute: 0).summary, "Daily at 09:00")
        XCTAssertEqual(JobSchedule.weekdays(days: [.friday, .monday], hour: 17, minute: 30).summary, "Mon, Fri at 17:30")
        XCTAssertEqual(JobSchedule.monthly(day: 31, hour: 8, minute: 1).summary, "Monthly on day 31 at 08:01")
        XCTAssertEqual(JobSchedule.interval(hours: 2, minutes: 15).summary, "Every 2 hr 15 min")
    }

    func testWeekdayCalendarMappingMatchesLaunchdCronNumbering() {
        XCTAssertEqual(LaunchdWeekday.monday.rawValue, 1)
        XCTAssertEqual(LaunchdWeekday.monday.foundationWeekday, 2)
        XCTAssertEqual(LaunchdWeekday.sunday.rawValue, 7)
        XCTAssertEqual(LaunchdWeekday.sunday.foundationWeekday, 1)
    }

    func testNextWeekdayRun() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: "2026-07-11T18:00:00Z")! // Saturday morning local
        let next = try XCTUnwrap(JobSchedule.weekdays(days: [.monday], hour: 9, minute: 0).nextRun(after: start, calendar: calendar))
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: next)
        XCTAssertEqual(components.weekday, 2)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
    }

    func testIntervalNextRunIsUnknownBecauseLaunchTimeAndSleepMatter() {
        XCTAssertNil(JobSchedule.interval(hours: 1, minutes: 0).nextRun(after: Date()))
    }

    func testSpringDSTGapUsesNextValidLocalTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 59))!
        let next = try XCTUnwrap(JobSchedule.daily(hour: 2, minute: 30).nextRun(after: start, calendar: calendar))
        let components = calendar.dateComponents([.day, .hour, .minute], from: next)
        XCTAssertEqual(components.day, 8)
        XCTAssertEqual(components.hour, 3)
        XCTAssertEqual(components.minute, 0)
    }
}
