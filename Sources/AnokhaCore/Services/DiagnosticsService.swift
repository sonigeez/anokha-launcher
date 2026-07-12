import Foundation

public enum DiagnosticCategory: String, Codable, Sendable {
    case fileMissing
    case fileNotExecutable
    case workingDirectoryMissing
    case invalidEnvironment
    case permissionDenied
    case installationFailed
    case launchFailed
    case nonzeroExit
    case repeatedlyFailing
    case externalChange
    case backgroundApprovalRequired
    case unavailable
    case unknown
}

public struct JobDiagnostic: Codable, Equatable, Identifiable, Sendable {
    public var category: DiagnosticCategory
    public var title: String
    public var message: String
    public var rawDetails: String?

    public var id: String { "\(category.rawValue):\(title):\(message)" }

    public init(category: DiagnosticCategory, title: String, message: String, rawDetails: String? = nil) {
        self.category = category
        self.title = title
        self.message = message
        self.rawDetails = rawDetails
    }
}

public struct DiagnosticsService: Sendable {
    public init() {}

    public func diagnostic(for issue: ValidationIssue) -> JobDiagnostic {
        switch issue.code {
        case .executableMissing:
            return .init(category: .fileMissing, title: "File missing", message: issue.message)
        case .executableNotExecutable:
            return .init(category: .fileNotExecutable, title: "File is not executable", message: issue.message)
        case .invalidWorkingDirectory:
            return .init(category: .workingDirectoryMissing, title: "Working directory unavailable", message: issue.message)
        case .invalidEnvironmentName, .duplicateEnvironmentName:
            return .init(category: .invalidEnvironment, title: "Environment is invalid", message: issue.message)
        default:
            return .init(category: .unknown, title: "Configuration problem", message: issue.message)
        }
    }

    public func diagnostic(for error: Error) -> JobDiagnostic {
        let detail = error.localizedDescription
        let lower = detail.lowercased()
        if lower.contains("operation not permitted") || lower.contains("permission denied") {
            return .init(
                category: .permissionDenied,
                title: "macOS denied access",
                message: "Grant access to the selected file or folder in System Settings, then try again.",
                rawDetails: detail
            )
        }
        if error is LaunchdClientError {
            return .init(
                category: .launchFailed,
                title: "LaunchAgent could not be loaded",
                message: "Check Background Items approval and the advanced launchctl details.",
                rawDetails: detail
            )
        }
        return .init(category: .unknown, title: "Operation failed", message: detail, rawDetails: detail)
    }

    public func diagnostic(for status: RunnerStatus) -> JobDiagnostic? {
        if status.state == .failedToLaunch {
            return .init(
                category: .launchFailed,
                title: "Command could not start",
                message: status.message ?? "The runner could not launch the configured command."
            )
        }
        if status.consecutiveFailures >= 3 {
            return .init(
                category: .repeatedlyFailing,
                title: "Job is repeatedly failing",
                message: "The command has failed \(status.consecutiveFailures) times and is being throttled between attempts."
            )
        }
        if let code = status.lastExitCode, code != 0 {
            return .init(
                category: .nonzeroExit,
                title: "Process exited with status \(code)",
                message: "Open Errors for the command's diagnostic output."
            )
        }
        return nil
    }
}
