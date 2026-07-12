import Foundation

public struct RunnerConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var jobID: UUID
    public var label: String
    public var command: JobCommand
    public var workingDirectory: String
    public var environment: [String: String]
    public var standardOutputPath: String
    public var standardErrorPath: String
    public var statusPath: String
    public var restartPolicy: RestartPolicy
    public var restartDelaySeconds: Int
    public var logPolicy: LogPolicy

    public init(
        version: Int = Self.currentVersion,
        jobID: UUID,
        label: String,
        command: JobCommand,
        workingDirectory: String,
        environment: [String: String],
        standardOutputPath: String,
        standardErrorPath: String,
        statusPath: String,
        restartPolicy: RestartPolicy,
        restartDelaySeconds: Int,
        logPolicy: LogPolicy
    ) {
        self.version = version
        self.jobID = jobID
        self.label = label
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardOutputPath = standardOutputPath
        self.standardErrorPath = standardErrorPath
        self.statusPath = statusPath
        self.restartPolicy = restartPolicy
        self.restartDelaySeconds = restartDelaySeconds
        self.logPolicy = logPolicy
    }
}

public struct RunnerStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case starting
        case running
        case waitingToRestart
        case exited
        case failedToLaunch
    }

    public var version: Int
    public var jobID: UUID
    public var state: State
    public var runnerPID: Int32
    public var childPID: Int32?
    public var lastStartedAt: Date?
    public var lastExitedAt: Date?
    public var lastExitCode: Int32?
    public var lastTerminationSignal: Int32?
    public var consecutiveFailures: Int
    public var runCount: Int
    public var message: String?

    public init(
        version: Int = 1,
        jobID: UUID,
        state: State,
        runnerPID: Int32,
        childPID: Int32? = nil,
        lastStartedAt: Date? = nil,
        lastExitedAt: Date? = nil,
        lastExitCode: Int32? = nil,
        lastTerminationSignal: Int32? = nil,
        consecutiveFailures: Int = 0,
        runCount: Int = 0,
        message: String? = nil
    ) {
        self.version = version
        self.jobID = jobID
        self.state = state
        self.runnerPID = runnerPID
        self.childPID = childPID
        self.lastStartedAt = lastStartedAt
        self.lastExitedAt = lastExitedAt
        self.lastExitCode = lastExitCode
        self.lastTerminationSignal = lastTerminationSignal
        self.consecutiveFailures = consecutiveFailures
        self.runCount = runCount
        self.message = message
    }
}
