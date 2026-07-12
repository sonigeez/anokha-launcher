import AnokhaCore
import Darwin
import Foundation

func fail(
    _ message: String,
    code: Int32,
    jobID: UUID? = nil,
    statusPath: String? = nil,
    errorLogPath: String? = nil
) -> Never {
    if let jobID, let statusPath {
        let status = RunnerStatus(
            jobID: jobID,
            state: .failedToLaunch,
            runnerPID: getpid(),
            lastExitedAt: Date(),
            lastExitCode: code,
            runCount: 1,
            message: message
        )
        if let data = try? JSONCoding.encoder().encode(status) {
            try? AtomicFile.write(data, to: URL(fileURLWithPath: statusPath), permissions: 0o600)
        }
    }
    if let errorLogPath,
       let writer = try? RollingLogWriter(
           url: URL(fileURLWithPath: errorLogPath),
           maxBytes: LogPolicy.default.maxBytesPerFile,
           backupCount: LogPolicy.default.retainedBackups
       ) {
        try? writer.append(Data("AnokhaJobRunner: \(message)\n".utf8))
    }
    FileHandle.standardError.write(Data("AnokhaJobRunner: \(message)\n".utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

guard let configurationPath = argument("--configuration"),
      let jobIDValue = argument("--job-id"),
      let jobID = UUID(uuidString: jobIDValue),
      let statusPath = argument("--status"),
      let errorLogPath = argument("--error-log") else {
    fail("usage: AnokhaJobRunner --configuration <path>", code: 64)
}

do {
    let data = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
    let configuration = try JSONCoding.decoder().decode(RunnerConfiguration.self, from: data)
    guard configuration.jobID == jobID,
          configuration.statusPath == statusPath,
          configuration.standardErrorPath == errorLogPath else {
        fail(
            "The runner arguments do not match the signed execution configuration.",
            code: 78,
            jobID: jobID,
            statusPath: statusPath,
            errorLogPath: errorLogPath
        )
    }
    let engine = try JobRunnerEngine(configuration: configuration)
    exit(engine.run())
} catch {
    fail(
        error.localizedDescription,
        code: 78,
        jobID: jobID,
        statusPath: statusPath,
        errorLogPath: errorLogPath
    )
}
