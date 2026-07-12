import Foundation

public enum JobSchedule: Codable, Hashable, Sendable {
    case hourly(minute: Int)
    case daily(hour: Int, minute: Int)
    case weekdays(days: Set<LaunchdWeekday>, hour: Int, minute: Int)
    case monthly(day: Int, hour: Int, minute: Int)
    case interval(hours: Int, minutes: Int)

    public var kind: JobScheduleKind {
        switch self {
        case .hourly: return .hourly
        case .daily: return .daily
        case .weekdays: return .weekdays
        case .monthly: return .monthly
        case .interval: return .interval
        }
    }

    public var summary: String {
        switch self {
        case .hourly(let minute):
            return String(format: "Hourly at :%02d", minute)
        case .daily(let hour, let minute):
            return "Daily at \(Self.time(hour: hour, minute: minute))"
        case .weekdays(let days, let hour, let minute):
            let names = days.sorted().map(\.shortName).joined(separator: ", ")
            return "\(names) at \(Self.time(hour: hour, minute: minute))"
        case .monthly(let day, let hour, let minute):
            return "Monthly on day \(day) at \(Self.time(hour: hour, minute: minute))"
        case .interval(let hours, let minutes):
            var pieces: [String] = []
            if hours > 0 { pieces.append("\(hours) hr") }
            if minutes > 0 { pieces.append("\(minutes) min") }
            return "Every \(pieces.joined(separator: " "))"
        }
    }

    public var intervalSeconds: Int? {
        guard case .interval(let hours, let minutes) = self else { return nil }
        return (hours * 60 + minutes) * 60
    }

    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .hourly(let minute):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(minute: minute),
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        case .daily(let hour, let minute):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute),
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        case .weekdays(let days, let hour, let minute):
            return days.compactMap { day in
                var components = DateComponents()
                components.weekday = day.foundationWeekday
                components.hour = hour
                components.minute = minute
                return calendar.nextDate(
                    after: date,
                    matching: components,
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                )
            }.min()
        case .monthly(let day, let hour, let minute):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(day: day, hour: hour, minute: minute),
                matchingPolicy: .strict,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        case .interval:
            // launchd intervals are measured from load time and missed while asleep,
            // so the app cannot honestly calculate an exact next firing here.
            return nil
        }
    }

    private static func time(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }
}

public enum JobScheduleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case hourly
    case daily
    case weekdays
    case monthly
    case interval

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// launchd follows cron numbering: Monday is 1; Sunday is 0 or 7.
public enum LaunchdWeekday: Int, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    case monday = 1
    case tuesday = 2
    case wednesday = 3
    case thursday = 4
    case friday = 5
    case saturday = 6
    case sunday = 7

    public var id: Int { rawValue }
    public static func < (lhs: LaunchdWeekday, rhs: LaunchdWeekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var shortName: String {
        switch self {
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        case .sunday: return "Sun"
        }
    }

    public var foundationWeekday: Int {
        self == .sunday ? 1 : rawValue + 1
    }
}
