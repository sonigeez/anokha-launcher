import AnokhaCore
import Foundation
import XCTest

final class CompilerTests: XCTestCase {
    private let compiler = LaunchAgentCompiler()
    private let runner = URL(fileURLWithPath: "/tmp/AnokhaJobRunner")
    private let config = URL(fileURLWithPath: "/tmp/job.json")

    func testShellAtLoginPlistIsDeterministic() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let job = JobDefinition.validShell(id: id)
        let status = URL(fileURLWithPath: "/tmp/status.json")
        let errorLog = URL(fileURLWithPath: "/tmp/stderr.log")
        let first = try compiler.compile(
            job,
            runnerExecutableURL: runner,
            configurationURL: config,
            statusURL: status,
            bootstrapErrorURL: errorLog,
            fileSystem: StubFileSystem()
        )
        let second = try compiler.compile(
            job,
            runnerExecutableURL: runner,
            configurationURL: config,
            statusURL: status,
            bootstrapErrorURL: errorLog,
            fileSystem: StubFileSystem()
        )
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.fingerprint, second.fingerprint)

        let root = try dictionary(first.root)
        XCTAssertEqual(root["Label"], .string("com.anokha.launcher.job.11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(root["RunAtLoad"], .boolean(true))
        XCTAssertNil(root["KeepAlive"])
        XCTAssertEqual(root["ProgramArguments"], .array([
            .string(runner.path),
            .string("--configuration"), .string(config.path),
            .string("--job-id"), .string(id.uuidString.lowercased()),
            .string("--status"), .string(status.path),
            .string("--error-log"), .string(errorLog.path)
        ]))
        XCTAssertEqual(root["AssociatedBundleIdentifiers"], .array([.string("com.anokha.launcher")]))

        _ = try PropertyListValue.decode(first.data)
    }

    func testDailyAndWeekdaySchedulesCompileExactly() throws {
        let daily = JobDefinition.validShell(activation: .scheduled(.daily(hour: 9, minute: 7)))
        let dailyRoot = try dictionary(compiler.compile(daily, runnerExecutableURL: runner, configurationURL: config, fileSystem: StubFileSystem()).root)
        XCTAssertEqual(dailyRoot["StartCalendarInterval"], .dictionary([
            "Hour": .integer(9), "Minute": .integer(7)
        ]))
        XCTAssertNil(dailyRoot["RunAtLoad"])

        let weekdays = JobDefinition.validShell(activation: .scheduled(.weekdays(days: [.friday, .monday, .sunday], hour: 8, minute: 30)))
        let weekdayRoot = try dictionary(compiler.compile(weekdays, runnerExecutableURL: runner, configurationURL: config, fileSystem: StubFileSystem()).root)
        XCTAssertEqual(weekdayRoot["StartCalendarInterval"], .array([
            .dictionary(["Hour": .integer(8), "Minute": .integer(30), "Weekday": .integer(1)]),
            .dictionary(["Hour": .integer(8), "Minute": .integer(30), "Weekday": .integer(5)]),
            .dictionary(["Hour": .integer(8), "Minute": .integer(30), "Weekday": .integer(7)])
        ]))
    }

    func testScheduledRestartOnFailureDoesNotImplicitlyRunAtLoad() throws {
        let job = JobDefinition.validShell(
            activation: .scheduled(.hourly(minute: 15)),
            restartPolicy: .onFailure
        )
        let root = try dictionary(compiler.compile(job, runnerExecutableURL: runner, configurationURL: config, fileSystem: StubFileSystem()).root)
        XCTAssertNil(root["RunAtLoad"])
        XCTAssertNil(root["KeepAlive"])
        XCTAssertEqual(root["StartCalendarInterval"], .dictionary(["Minute": .integer(15)]))
    }

    func testKeepRunningUsesKeepAliveAndThrottle() throws {
        var job = JobDefinition.validShell(activation: .keepRunning, restartPolicy: .always)
        job.restartDelaySeconds = 25
        let root = try dictionary(compiler.compile(job, runnerExecutableURL: runner, configurationURL: config, fileSystem: StubFileSystem()).root)
        XCTAssertEqual(root["RunAtLoad"], .boolean(true))
        XCTAssertEqual(root["KeepAlive"], .boolean(true))
        XCTAssertEqual(root["ThrottleInterval"], .integer(25))
    }

    func testExecutionPlanPreservesDirectArgumentsAndPathOverride() throws {
        let path = "/tmp/a tool"
        let fileSystem = StubFileSystem(
            existing: [path],
            regularFiles: [path],
            executableFiles: [path],
            permissions: [path: 0o755]
        )
        let job = JobDefinition(
            name: "Arguments",
            command: .file(path: path, arguments: ["hello world", "", "'quoted'"]),
            environment: [EnvironmentVariable(key: "PATH", value: "/custom/bin")]
        )
        let base = URL(fileURLWithPath: "/tmp/anokha")
        let paths = AppPaths(applicationSupportDirectory: base, launchAgentsDirectory: base.appendingPathComponent("agents"))
        let plan = try ExecutionPlanCompiler().compile(job, paths: paths, fileSystem: fileSystem)
        XCTAssertEqual(plan.command, .file(path: path, arguments: ["hello world", "", "'quoted'"]))
        XCTAssertEqual(plan.environment["PATH"], "/custom/bin")
    }

    func testImporterLosslesslyAdoptsSupportedScheduleChange() throws {
        let current = JobDefinition.validShell()
        let original = try compiler.compile(
            current,
            runnerExecutableURL: runner,
            configurationURL: config,
            fileSystem: StubFileSystem()
        )
        var values = try dictionary(original.root)
        values.removeValue(forKey: "RunAtLoad")
        values["StartCalendarInterval"] = .dictionary([
            "Hour": .integer(14),
            "Minute": .integer(5)
        ])
        let imported = try LaunchAgentImporter().importSupportedChanges(
            from: PropertyListValue.dictionary(values).xmlData(),
            current: current,
            runnerExecutableURL: runner,
            configurationURL: config,
            fileSystem: StubFileSystem()
        )
        XCTAssertEqual(imported.activation, .scheduled(.daily(hour: 14, minute: 5)))
    }

    func testImporterRejectsArbitraryPropertyListKeys() throws {
        let current = JobDefinition.validShell()
        let original = try compiler.compile(
            current,
            runnerExecutableURL: runner,
            configurationURL: config,
            fileSystem: StubFileSystem()
        )
        var values = try dictionary(original.root)
        values["WatchPaths"] = .array([.string("/tmp")])
        XCTAssertThrowsError(try LaunchAgentImporter().importSupportedChanges(
            from: PropertyListValue.dictionary(values).xmlData(),
            current: current,
            runnerExecutableURL: runner,
            configurationURL: config,
            fileSystem: StubFileSystem()
        ))
    }

    private func dictionary(_ value: PropertyListValue) throws -> [String: PropertyListValue] {
        guard case .dictionary(let dictionary) = value else {
            throw XCTSkip("Expected dictionary")
        }
        return dictionary
    }
}
