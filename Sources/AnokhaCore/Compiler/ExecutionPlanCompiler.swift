import Foundation

public enum JobConfigurationError: LocalizedError {
    case validationFailed(ValidationReport)
    case unsupportedConfigurationVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .validationFailed(let report):
            return report.errors.map(\.message).joined(separator: " ")
        case .unsupportedConfigurationVersion(let version):
            return "Unsupported runner configuration version \(version)."
        }
    }
}

public struct ExecutionPlanCompiler: Sendable {
    public init() {}

    public func compile(
        _ job: JobDefinition,
        paths: AppPaths,
        fileSystem: any FileSystemChecking = LiveFileSystem()
    ) throws -> RunnerConfiguration {
        let report = job.validate(fileSystem: fileSystem)
        guard report.isValid else {
            throw JobConfigurationError.validationFailed(report)
        }

        var environment = ["PATH": JobDefinition.defaultPath]
        for variable in job.environment {
            environment[variable.key] = variable.value
        }

        return RunnerConfiguration(
            jobID: job.id,
            label: job.label,
            command: job.command,
            workingDirectory: job.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path,
            environment: environment,
            standardOutputPath: paths.standardOutputURL(for: job.id).path,
            standardErrorPath: paths.standardErrorURL(for: job.id).path,
            statusPath: paths.statusURL(for: job.id).path,
            restartPolicy: job.restartPolicy,
            restartDelaySeconds: job.restartDelaySeconds,
            logPolicy: job.logPolicy
        )
    }
}
