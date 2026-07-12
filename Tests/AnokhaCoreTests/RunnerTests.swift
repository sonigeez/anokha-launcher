import AnokhaCore
import Darwin
import Foundation
import XCTest

final class RunnerTests: XCTestCase {
    func testFileArgumentsArePassedWithoutShellReparsing() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let script = base.appendingPathComponent("tool with spaces")
        let scriptBody = "#!/bin/sh\nprintf '<%s>\\n' \"$@\"\nprintf 'problem\\n' >&2\n"
        try AtomicFile.write(Data(scriptBody.utf8), to: script, permissions: 0o755)
        let configuration = configuration(
            base: base,
            command: .file(path: script.path, arguments: ["hello world", "", "unicøde"]),
            restartPolicy: .never
        )

        let code = try JobRunnerEngine(configuration: configuration).run()
        XCTAssertEqual(code, 0)
        let stdout = try String(contentsOfFile: configuration.standardOutputPath, encoding: .utf8)
        let stderr = try String(contentsOfFile: configuration.standardErrorPath, encoding: .utf8)
        XCTAssertEqual(stdout, "<hello world>\n<>\n<unicøde>\n")
        XCTAssertEqual(stderr, "problem\n")

        let statusData = try Data(contentsOf: URL(fileURLWithPath: configuration.statusPath))
        let status = try JSONCoding.decoder().decode(RunnerStatus.self, from: statusData)
        XCTAssertEqual(status.state, .exited)
        XCTAssertEqual(status.lastExitCode, 0)
        XCTAssertEqual(status.runCount, 1)
    }

    func testRestartOnFailureStopsAfterSuccess() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let marker = base.appendingPathComponent("attempted")
        let script = base.appendingPathComponent("fail-once")
        let body = """
        #!/bin/sh
        if [ ! -e "\(marker.path)" ]; then
          touch "\(marker.path)"
          echo first-failure >&2
          exit 42
        fi
        echo recovered
        exit 0
        """
        try AtomicFile.write(Data(body.utf8), to: script, permissions: 0o755)
        var config = configuration(base: base, command: .file(path: script.path, arguments: []), restartPolicy: .onFailure)
        config.restartDelaySeconds = 0 // Runtime fixture: avoid a ten-second unit-test delay.
        let code = try JobRunnerEngine(configuration: config).run()
        XCTAssertEqual(code, 0)
        let status = try JSONCoding.decoder().decode(
            RunnerStatus.self,
            from: Data(contentsOf: URL(fileURLWithPath: config.statusPath))
        )
        XCTAssertEqual(status.runCount, 2)
        XCTAssertEqual(status.lastExitCode, 0)
        XCTAssertEqual(status.consecutiveFailures, 0)
    }

    func testMalformedConfigurationWritesBoundedBootstrapDiagnostics() throws {
        let runner = try locateRunner()
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let configURL = base.appendingPathComponent("broken.json")
        let statusURL = base.appendingPathComponent("status.json")
        let errorURL = base.appendingPathComponent("stderr.log")
        let jobID = UUID()
        try AtomicFile.write(Data("not json".utf8), to: configURL)

        let process = Process()
        let diagnosticPipe = Pipe()
        process.executableURL = runner
        process.standardError = diagnosticPipe
        process.arguments = runnerArguments(
            configurationURL: configURL,
            jobID: jobID,
            statusURL: statusURL,
            errorURL: errorURL
        )
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 78)
        let status = try JSONCoding.decoder().decode(RunnerStatus.self, from: Data(contentsOf: statusURL))
        XCTAssertEqual(status.state, .failedToLaunch)
        XCTAssertEqual(status.lastExitCode, 78)
        XCTAssertTrue(try String(contentsOf: errorURL, encoding: .utf8).contains("AnokhaJobRunner"))
    }

    func testTermIgnoringChildIsKilledAfterGracePeriod() throws {
        let runner = try locateRunner()
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let childPIDURL = base.appendingPathComponent("child.pid")
        let script = base.appendingPathComponent("ignore-term")
        let body = """
        #!/bin/sh
        trap '' TERM INT HUP
        echo $$ > "\(childPIDURL.path)"
        while :; do sleep 1; done
        """
        try AtomicFile.write(Data(body.utf8), to: script, permissions: 0o755)
        let config = configuration(base: base, command: .file(path: script.path, arguments: []), restartPolicy: .never)
        let process = try startRunner(runner, configuration: config, base: base)
        var childPID: pid_t = 0
        defer {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            if childPID > 0 { Darwin.kill(-childPID, SIGKILL) }
        }
        try poll(timeout: 5) {
            guard let value = try? String(contentsOf: childPIDURL, encoding: .utf8),
                  let parsed = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            childPID = parsed
            return true
        }

        process.terminate()
        try poll(timeout: 7) { !process.isRunning }
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(Darwin.kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testAlwaysPolicyRelaunchesAfterSuccessfulExit() throws {
        let runner = try locateRunner()
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let countURL = base.appendingPathComponent("count")
        let script = base.appendingPathComponent("count-runs")
        let body = """
        #!/bin/sh
        n=0
        if [ -f "\(countURL.path)" ]; then n=$(cat "\(countURL.path)"); fi
        n=$((n + 1))
        echo "$n" > "\(countURL.path)"
        if [ "$n" -ge 3 ]; then sleep 30; fi
        exit 0
        """
        try AtomicFile.write(Data(body.utf8), to: script, permissions: 0o755)
        var config = configuration(base: base, command: .file(path: script.path, arguments: []), restartPolicy: .always)
        config.restartDelaySeconds = 0
        let process = try startRunner(runner, configuration: config, base: base)
        defer { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

        try poll(timeout: 5) {
            guard let value = try? String(contentsOf: countURL, encoding: .utf8) else { return false }
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 >= 3
        }
        process.terminate()
        try poll(timeout: 5) { !process.isRunning }
        XCTAssertFalse(process.isRunning)
    }

    private func configuration(base: URL, command: JobCommand, restartPolicy: RestartPolicy) -> RunnerConfiguration {
        RunnerConfiguration(
            jobID: UUID(),
            label: "com.anokha.launcher.job.test",
            command: command,
            workingDirectory: base.path,
            environment: ["PATH": JobDefinition.defaultPath],
            standardOutputPath: base.appendingPathComponent("stdout.log").path,
            standardErrorPath: base.appendingPathComponent("stderr.log").path,
            statusPath: base.appendingPathComponent("status.json").path,
            restartPolicy: restartPolicy,
            restartDelaySeconds: 10,
            logPolicy: LogPolicy(maxBytesPerFile: 1_024 * 1_024, retainedBackups: 1)
        )
    }

    private func startRunner(_ runner: URL, configuration: RunnerConfiguration, base: URL) throws -> Process {
        let configurationURL = base.appendingPathComponent("configuration.json")
        try AtomicFile.write(try JSONCoding.encoder().encode(configuration), to: configurationURL)
        let process = Process()
        process.executableURL = runner
        process.arguments = runnerArguments(
            configurationURL: configurationURL,
            jobID: configuration.jobID,
            statusURL: URL(fileURLWithPath: configuration.statusPath),
            errorURL: URL(fileURLWithPath: configuration.standardErrorPath)
        )
        try process.run()
        return process
    }

    private func runnerArguments(configurationURL: URL, jobID: UUID, statusURL: URL, errorURL: URL) -> [String] {
        [
            "--configuration", configurationURL.path,
            "--job-id", jobID.uuidString.lowercased(),
            "--status", statusURL.path,
            "--error-log", errorURL.path
        ]
    }

    private func locateRunner() throws -> URL {
        if let value = ProcessInfo.processInfo.environment["ANOKHA_RUNNER_PATH"] {
            return URL(fileURLWithPath: value)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            root.appendingPathComponent(".build/debug/AnokhaJobRunner"),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/AnokhaJobRunner")
        ]
        guard let runner = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("Build AnokhaJobRunner first or set ANOKHA_RUNNER_PATH.")
        }
        return runner
    }

    private func poll(timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Condition was not met within \(timeout) seconds")
    }
}
