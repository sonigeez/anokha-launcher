import Foundation

public enum LaunchAgentImportError: LocalizedError, Equatable {
    case invalidPropertyList
    case unsupportedChange(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPropertyList:
            return "The installed file is not a supported LaunchAgent property list."
        case .unsupportedChange(let detail):
            return "The external change cannot be adopted safely: \(detail)"
        }
    }
}

/// Losslessly imports supported trigger edits from an app-owned plist. The
/// generated document must match the external tree exactly; arbitrary keys or
/// changes to the runner/configuration boundary are rejected.
public struct LaunchAgentImporter: Sendable {
    private let compiler = LaunchAgentCompiler()

    public init() {}

    public func importSupportedChanges(
        from data: Data,
        current: JobDefinition,
        runnerExecutableURL: URL,
        configurationURL: URL,
        fileSystem: any FileSystemChecking = LiveFileSystem()
    ) throws -> JobDefinition {
        let external = try PropertyListValue.decode(data)
        guard case .dictionary(let values) = external else {
            throw LaunchAgentImportError.invalidPropertyList
        }

        var adopted = current
        adopted.activation = try activation(from: values)
        switch adopted.activation {
        case .keepRunning:
            adopted.restartPolicy = .always
            guard case .integer(let delay)? = values["ThrottleInterval"] else {
                throw LaunchAgentImportError.unsupportedChange("Keep-running jobs require an explicit throttle interval.")
            }
            adopted.restartDelaySeconds = delay
        case .manual:
            adopted.restartPolicy = .never
        case .atLogin, .scheduled:
            if adopted.restartPolicy == .always { adopted.restartPolicy = .never }
        }

        let regenerated = try compiler.compile(
            adopted,
            runnerExecutableURL: runnerExecutableURL,
            configurationURL: configurationURL,
            fileSystem: fileSystem
        )
        guard regenerated.root == external else {
            throw LaunchAgentImportError.unsupportedChange(
                "Only lossless changes to supported login, schedule, manual, and keep-running triggers can be adopted."
            )
        }
        return adopted
    }

    private func activation(from values: [String: PropertyListValue]) throws -> JobActivation {
        let runAtLoad = values["RunAtLoad"] == .boolean(true)
        let keepAlive = values["KeepAlive"]
        let calendar = values["StartCalendarInterval"]
        let interval = values["StartInterval"]

        let triggerCount = [keepAlive, calendar, interval].compactMap { $0 }.count
        if triggerCount > 1 {
            throw LaunchAgentImportError.unsupportedChange("Multiple automatic trigger families are not supported together.")
        }

        if let keepAlive {
            guard keepAlive == .boolean(true), runAtLoad else {
                throw LaunchAgentImportError.unsupportedChange("The KeepAlive edit is not a supported keep-running preset.")
            }
            return .keepRunning
        }
        if let calendar {
            guard !runAtLoad else {
                throw LaunchAgentImportError.unsupportedChange("Scheduled jobs cannot also run at load.")
            }
            return .scheduled(try schedule(fromCalendarValue: calendar))
        }
        if let interval {
            guard !runAtLoad, case .integer(let seconds) = interval, seconds > 0, seconds % 60 == 0 else {
                throw LaunchAgentImportError.unsupportedChange("Repeat intervals must be positive whole minutes.")
            }
            let totalMinutes = seconds / 60
            return .scheduled(.interval(hours: totalMinutes / 60, minutes: totalMinutes % 60))
        }
        return runAtLoad ? .atLogin : .manual
    }

    private func schedule(fromCalendarValue value: PropertyListValue) throws -> JobSchedule {
        switch value {
        case .dictionary(let dictionary):
            return try schedule(fromCalendarDictionary: dictionary)
        case .array(let entries):
            guard !entries.isEmpty else {
                throw LaunchAgentImportError.unsupportedChange("Weekday schedules cannot be empty.")
            }
            var weekdays: Set<LaunchdWeekday> = []
            var sharedHour: Int?
            var sharedMinute: Int?
            for entry in entries {
                guard case .dictionary(let dictionary) = entry,
                      Set(dictionary.keys) == Set(["Weekday", "Hour", "Minute"]),
                      case .integer(let weekdayValue)? = dictionary["Weekday"],
                      let weekday = LaunchdWeekday(rawValue: weekdayValue),
                      case .integer(let hour)? = dictionary["Hour"],
                      case .integer(let minute)? = dictionary["Minute"] else {
                    throw LaunchAgentImportError.unsupportedChange("The weekday schedule has unsupported fields.")
                }
                if let sharedHour, sharedHour != hour { throw LaunchAgentImportError.unsupportedChange("All selected weekdays must use one time.") }
                if let sharedMinute, sharedMinute != minute { throw LaunchAgentImportError.unsupportedChange("All selected weekdays must use one time.") }
                guard weekdays.insert(weekday).inserted else {
                    throw LaunchAgentImportError.unsupportedChange("A weekday is listed more than once.")
                }
                sharedHour = hour
                sharedMinute = minute
            }
            return .weekdays(days: weekdays, hour: sharedHour!, minute: sharedMinute!)
        default:
            throw LaunchAgentImportError.unsupportedChange("The calendar trigger has an unsupported shape.")
        }
    }

    private func schedule(fromCalendarDictionary values: [String: PropertyListValue]) throws -> JobSchedule {
        let keys = Set(values.keys)
        if keys == Set(["Minute"]), case .integer(let minute)? = values["Minute"] {
            return .hourly(minute: minute)
        }
        if keys == Set(["Hour", "Minute"]),
           case .integer(let hour)? = values["Hour"],
           case .integer(let minute)? = values["Minute"] {
            return .daily(hour: hour, minute: minute)
        }
        if keys == Set(["Day", "Hour", "Minute"]),
           case .integer(let day)? = values["Day"],
           case .integer(let hour)? = values["Hour"],
           case .integer(let minute)? = values["Minute"] {
            return .monthly(day: day, hour: hour, minute: minute)
        }
        throw LaunchAgentImportError.unsupportedChange("The calendar trigger does not match an editor-supported schedule.")
    }
}
