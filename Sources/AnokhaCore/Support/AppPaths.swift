import Foundation

public struct AppPaths: Sendable {
    public let applicationSupportDirectory: URL
    public let launchAgentsDirectory: URL

    public init(applicationSupportDirectory: URL, launchAgentsDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.launchAgentsDirectory = launchAgentsDirectory
    }

    public static var live: AppPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AppPaths(
            applicationSupportDirectory: home
                .appendingPathComponent("Library/Application Support/AnokhaLauncher", isDirectory: true),
            launchAgentsDirectory: home
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        )
    }

    public var recordsURL: URL {
        applicationSupportDirectory.appendingPathComponent("jobs.json")
    }

    public var runnerExecutableURL: URL {
        applicationSupportDirectory.appendingPathComponent("bin/AnokhaJobRunner")
    }

    public func configurationURL(for id: UUID) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("configurations", isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    public func statusURL(for id: UUID) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("status", isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    public func logDirectory(for id: UUID) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    public func standardOutputURL(for id: UUID) -> URL {
        logDirectory(for: id).appendingPathComponent("stdout.log")
    }

    public func standardErrorURL(for id: UUID) -> URL {
        logDirectory(for: id).appendingPathComponent("stderr.log")
    }

    public func launchAgentURL(for definition: JobDefinition) -> URL {
        launchAgentsDirectory.appendingPathComponent("\(definition.label).plist")
    }
}
