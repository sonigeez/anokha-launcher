import Foundation

public struct LaunchAgentDocument: Equatable, Sendable {
    public var root: PropertyListValue

    public init(root: PropertyListValue) {
        self.root = root
    }

    public var data: Data { root.xmlData() }
    public var fingerprint: String { root.fingerprint }
}

public struct LaunchAgentCompiler: Sendable {
    public static let applicationBundleIdentifier = "com.anokha.launcher"

    public init() {}

    public func compile(
        _ job: JobDefinition,
        runnerExecutableURL: URL,
        configurationURL: URL,
        statusURL: URL? = nil,
        bootstrapErrorURL: URL? = nil,
        fileSystem: any FileSystemChecking = LiveFileSystem()
    ) throws -> LaunchAgentDocument {
        let report = job.validate(fileSystem: fileSystem)
        guard report.isValid else {
            throw JobConfigurationError.validationFailed(report)
        }

        let supportRoot = configurationURL.deletingLastPathComponent().deletingLastPathComponent()
        let resolvedStatusURL = statusURL ?? supportRoot
            .appendingPathComponent("status", isDirectory: true)
            .appendingPathComponent("\(job.id.uuidString.lowercased()).json")
        let resolvedErrorURL = bootstrapErrorURL ?? supportRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(job.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("stderr.log")

        var values: [String: PropertyListValue] = [
            "AssociatedBundleIdentifiers": .array([.string(Self.applicationBundleIdentifier)]),
            "Label": .string(job.label),
            "LimitLoadToSessionType": .string("Aqua"),
            "ProcessType": .string("Background"),
            "ProgramArguments": .array([
                .string(runnerExecutableURL.path),
                .string("--configuration"),
                .string(configurationURL.path),
                .string("--job-id"),
                .string(job.id.uuidString.lowercased()),
                .string("--status"),
                .string(resolvedStatusURL.path),
                .string("--error-log"),
                .string(resolvedErrorURL.path)
            ]),
            // The runner captures child output and rotates it. Its own streams stay quiet.
            "StandardErrorPath": .string("/dev/null"),
            "StandardOutPath": .string("/dev/null")
        ]

        switch job.activation {
        case .atLogin:
            values["RunAtLoad"] = .boolean(true)
        case .scheduled(let schedule):
            apply(schedule: schedule, to: &values)
        case .keepRunning:
            values["RunAtLoad"] = .boolean(true)
            values["KeepAlive"] = .boolean(true)
            values["ThrottleInterval"] = .integer(max(10, job.restartDelaySeconds))
        case .manual:
            break
        }

        return LaunchAgentDocument(root: .dictionary(values))
    }

    private func apply(schedule: JobSchedule, to values: inout [String: PropertyListValue]) {
        switch schedule {
        case .hourly(let minute):
            values["StartCalendarInterval"] = .dictionary(["Minute": .integer(minute)])
        case .daily(let hour, let minute):
            values["StartCalendarInterval"] = .dictionary([
                "Hour": .integer(hour),
                "Minute": .integer(minute)
            ])
        case .weekdays(let days, let hour, let minute):
            values["StartCalendarInterval"] = .array(days.sorted().map { day in
                .dictionary([
                    "Hour": .integer(hour),
                    "Minute": .integer(minute),
                    "Weekday": .integer(day.rawValue)
                ])
            })
        case .monthly(let day, let hour, let minute):
            values["StartCalendarInterval"] = .dictionary([
                "Day": .integer(day),
                "Hour": .integer(hour),
                "Minute": .integer(minute)
            ])
        case .interval(let hours, let minutes):
            values["StartInterval"] = .integer((hours * 60 + minutes) * 60)
        }
    }
}
