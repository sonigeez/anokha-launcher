import AnokhaCore
import XCTest

final class ValidationTests: XCTestCase {
    func testEmptyShellCommandIsRejected() {
        let job = JobDefinition(name: "Blank", command: .shell(command: "  \n"))
        let report = job.validate(fileSystem: StubFileSystem())
        XCTAssertTrue(report.errors.contains { $0.code == .emptyShellCommand })
    }

    func testFileModeValidatesPathTypePermissionsAndArguments() {
        let path = "/tmp/tool with spaces"
        let fileSystem = StubFileSystem(
            existing: [path],
            regularFiles: [path],
            executableFiles: [path],
            permissions: [path: 0o755]
        )
        let job = JobDefinition(
            name: "Direct",
            command: .file(path: path, arguments: ["hello world", "", "unicøde"])
        )
        XCTAssertTrue(job.validate(fileSystem: fileSystem).isValid)
    }

    func testWorldWritableExecutableProducesWarningNotError() {
        let path = "/tmp/tool"
        let fileSystem = StubFileSystem(
            existing: [path],
            regularFiles: [path],
            executableFiles: [path],
            permissions: [path: 0o777]
        )
        let job = JobDefinition(name: "Risky", command: .file(path: path, arguments: []))
        let report = job.validate(fileSystem: fileSystem)
        XCTAssertTrue(report.isValid)
        XCTAssertTrue(report.warnings.contains { $0.code == .executableWritableByOthers })
    }

    func testEnvironmentNamesAndDuplicatesAreRejected() {
        let job = JobDefinition(
            name: "Environment",
            command: .shell(command: "true"),
            environment: [
                EnvironmentVariable(key: "GOOD", value: "1"),
                EnvironmentVariable(key: "GOOD", value: "2"),
                EnvironmentVariable(key: "BAD-NAME", value: "3")
            ]
        )
        let report = job.validate(fileSystem: StubFileSystem())
        XCTAssertTrue(report.errors.contains { $0.code == .duplicateEnvironmentName })
        XCTAssertTrue(report.errors.contains { $0.code == .invalidEnvironmentName })
        XCTAssertTrue(report.warnings.contains { $0.code == .plaintextEnvironment })
    }

    func testContradictoryLifecycleCombinationsAreRejected() {
        var manual = JobDefinition.validShell(activation: .manual, restartPolicy: .onFailure)
        XCTAssertTrue(manual.validate(fileSystem: StubFileSystem()).errors.contains { $0.code == .contradictoryLifecycle })

        manual.activation = .keepRunning
        manual.restartPolicy = .never
        XCTAssertTrue(manual.validate(fileSystem: StubFileSystem()).errors.contains { $0.code == .contradictoryLifecycle })

        manual.activation = .scheduled(.daily(hour: 9, minute: 0))
        manual.restartPolicy = .always
        XCTAssertTrue(manual.validate(fileSystem: StubFileSystem()).errors.contains { $0.code == .contradictoryLifecycle })
    }

    func testRestartDelayHasTenSecondMinimum() {
        var job = JobDefinition.validShell(restartPolicy: .onFailure)
        job.restartDelaySeconds = 9
        XCTAssertTrue(job.validate(fileSystem: StubFileSystem()).errors.contains { $0.code == .restartDelayTooShort })
    }

    func testInvalidSchedulesAreRejected() {
        let schedules: [JobSchedule] = [
            .hourly(minute: 60),
            .daily(hour: 24, minute: 0),
            .weekdays(days: [], hour: 9, minute: 0),
            .monthly(day: 0, hour: 9, minute: 0),
            .interval(hours: 0, minutes: 0)
        ]
        for schedule in schedules {
            let job = JobDefinition.validShell(activation: .scheduled(schedule))
            XCTAssertTrue(job.validate(fileSystem: StubFileSystem()).errors.contains { $0.code == .invalidSchedule })
        }
    }
}
