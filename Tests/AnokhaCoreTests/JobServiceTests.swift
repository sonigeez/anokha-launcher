import AnokhaCore
import Foundation
import XCTest

final class JobServiceTests: XCTestCase {
    func testIncompleteJobCanBeSavedDisabledButNotEnabled() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(
            applicationSupportDirectory: base.appendingPathComponent("support"),
            launchAgentsDirectory: base.appendingPathComponent("agents")
        )
        let missingRunner = base.appendingPathComponent("missing-runner")
        let service = JobService(paths: paths, bundledRunnerURL: missingRunner)
        let draft = JobDefinition(name: "Draft", command: .shell(command: ""))
        let record = try service.save(definition: draft, enabled: false)
        XCTAssertFalse(record.enabled)
        XCTAssertThrowsError(try service.enable(id: record.id)) { error in
            guard case JobConfigurationError.validationFailed = error else {
                return XCTFail("Expected validation failure, got \(error)")
            }
        }
    }

    func testBootedOutServiceDoesNotLookRunningFromStaleStatusFile() {
        let job = JobDefinition.validShell()
        let record = ManagedJobRecord(definition: job, enabled: true, installedFingerprint: "fingerprint")
        let staleStatus = RunnerStatus(
            jobID: job.id,
            state: .running,
            runnerPID: 99,
            childPID: 100,
            lastStartedAt: Date()
        )
        let snapshot = JobSnapshot(
            record: record,
            reconciliation: .inSync,
            launchd: LaunchdSnapshot(loadState: .notLoaded),
            runner: staleStatus,
            approval: .notRegistered,
            diagnostic: nil
        )
        XCTAssertEqual(snapshot.displayState, .stopped)
    }

    func testEnableAndDisableManageExactPersistentArtifacts() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(
            applicationSupportDirectory: base.appendingPathComponent("support"),
            launchAgentsDirectory: base.appendingPathComponent("agents")
        )
        let sourceRunner = base.appendingPathComponent("bundled-runner")
        try AtomicFile.write(Data("runner".utf8), to: sourceRunner, permissions: 0o755)
        let executor = ServiceExecutor(results: [success(), success()])
        let launchd = LaunchdClient(userID: 501, executor: executor)
        let service = JobService(paths: paths, bundledRunnerURL: sourceRunner, launchd: launchd)

        let enabled = try service.save(definition: .validShell(), enabled: true)
        XCTAssertTrue(enabled.enabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.launchAgentURL(for: enabled.definition).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configurationURL(for: enabled.id).path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.runnerExecutableURL.path))

        let disabled = try service.disable(id: enabled.id)
        XCTAssertFalse(disabled.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.launchAgentURL(for: enabled.definition).path))
        XCTAssertEqual(executor.invocations.map { $0.first }, ["bootstrap", "bootout"])
    }

    func testFailedBootstrapRollsBackNewPersistentArtifacts() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(
            applicationSupportDirectory: base.appendingPathComponent("support"),
            launchAgentsDirectory: base.appendingPathComponent("agents")
        )
        let sourceRunner = base.appendingPathComponent("bundled-runner")
        try AtomicFile.write(Data("runner".utf8), to: sourceRunner, permissions: 0o755)
        let executor = ServiceExecutor(results: [
            ProcessResult(executable: "/bin/launchctl", arguments: [], exitCode: 5, standardOutput: "", standardError: "rejected"),
            ProcessResult(executable: "/bin/launchctl", arguments: [], exitCode: 3, standardOutput: "", standardError: "Could not find service")
        ])
        let service = JobService(
            paths: paths,
            bundledRunnerURL: sourceRunner,
            launchd: LaunchdClient(userID: 501, executor: executor)
        )
        let job = JobDefinition.validShell()

        XCTAssertThrowsError(try service.save(definition: job, enabled: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.launchAgentURL(for: job).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configurationURL(for: job.id).path))
        XCTAssertTrue(try service.repository.loadRecords().isEmpty)
    }

    func testRestoreUnexpectedPlistKeepsDisabledRecordDisabled() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(
            applicationSupportDirectory: base.appendingPathComponent("support"),
            launchAgentsDirectory: base.appendingPathComponent("agents")
        )
        let executor = ServiceExecutor(results: [success()])
        let service = JobService(
            paths: paths,
            bundledRunnerURL: base.appendingPathComponent("unused-runner"),
            launchd: LaunchdClient(userID: 501, executor: executor)
        )
        let record = try service.save(definition: .validShell(), enabled: false)
        let stray = try LaunchAgentCompiler().compile(
            record.definition,
            runnerExecutableURL: paths.runnerExecutableURL,
            configurationURL: paths.configurationURL(for: record.id),
            fileSystem: StubFileSystem()
        )
        try AtomicFile.write(stray.data, to: paths.launchAgentURL(for: record.definition))
        guard case .unexpectedInstalledFile = service.repository.reconcile(record) else {
            return XCTFail("Expected stray plist conflict")
        }

        let restored = try service.restoreManagedVersion(id: record.id)
        XCTAssertFalse(restored.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.launchAgentURL(for: record.definition).path))
        XCTAssertEqual(executor.invocations.map { $0.first }, ["bootout"])
    }

    func testFailedUpdateReportsRollbackBootstrapFailure() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(
            applicationSupportDirectory: base.appendingPathComponent("support"),
            launchAgentsDirectory: base.appendingPathComponent("agents")
        )
        let sourceRunner = base.appendingPathComponent("bundled-runner")
        try AtomicFile.write(Data("runner".utf8), to: sourceRunner, permissions: 0o755)
        let failure = ProcessResult(executable: "/bin/launchctl", arguments: [], exitCode: 5, standardOutput: "", standardError: "failed")
        let executor = ServiceExecutor(results: [success(), success(), failure, success(), failure])
        let service = JobService(
            paths: paths,
            bundledRunnerURL: sourceRunner,
            launchd: LaunchdClient(userID: 501, executor: executor)
        )
        let original = try service.save(definition: .validShell(), enabled: true)
        var edited = original.definition
        edited.command = .shell(command: "echo changed")

        XCTAssertThrowsError(try service.save(
            definition: edited,
            enabled: true,
            expectedRevision: original.revision
        )) { error in
            guard case JobServiceError.rollbackFailed = error else {
                return XCTFail("Expected composite rollback failure, got \(error)")
            }
        }
        XCTAssertEqual(try service.repository.record(id: original.id).definition.command, original.definition.command)
        XCTAssertEqual(service.repository.reconcile(original), .inSync)
    }

    func testStopKeepsScheduledServiceLoadedButBootsOutKeepRunningService() throws {
        let scheduledBase = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scheduledBase) }
        let scheduledPaths = AppPaths(
            applicationSupportDirectory: scheduledBase.appendingPathComponent("support"),
            launchAgentsDirectory: scheduledBase.appendingPathComponent("agents")
        )
        let scheduledRunner = scheduledBase.appendingPathComponent("runner")
        try AtomicFile.write(Data("runner".utf8), to: scheduledRunner, permissions: 0o755)
        let scheduledExecutor = ServiceExecutor(results: [success(), success()])
        let scheduledService = JobService(
            paths: scheduledPaths,
            bundledRunnerURL: scheduledRunner,
            launchd: LaunchdClient(userID: 501, executor: scheduledExecutor)
        )
        let scheduledJob = JobDefinition.validShell(activation: .scheduled(.daily(hour: 9, minute: 0)))
        let scheduledRecord = try scheduledService.save(definition: scheduledJob, enabled: true)
        try scheduledService.stop(id: scheduledRecord.id)
        XCTAssertEqual(scheduledExecutor.invocations.map { $0.first }, ["bootstrap", "kill"])

        let keepAliveBase = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: keepAliveBase) }
        let keepAlivePaths = AppPaths(
            applicationSupportDirectory: keepAliveBase.appendingPathComponent("support"),
            launchAgentsDirectory: keepAliveBase.appendingPathComponent("agents")
        )
        let keepAliveRunner = keepAliveBase.appendingPathComponent("runner")
        try AtomicFile.write(Data("runner".utf8), to: keepAliveRunner, permissions: 0o755)
        let keepAliveExecutor = ServiceExecutor(results: [success(), success()])
        let keepAliveService = JobService(
            paths: keepAlivePaths,
            bundledRunnerURL: keepAliveRunner,
            launchd: LaunchdClient(userID: 501, executor: keepAliveExecutor)
        )
        let keepAliveJob = JobDefinition.validShell(activation: .keepRunning, restartPolicy: .always)
        let keepAliveRecord = try keepAliveService.save(definition: keepAliveJob, enabled: true)
        try keepAliveService.stop(id: keepAliveRecord.id)
        XCTAssertEqual(keepAliveExecutor.invocations.map { $0.first }, ["bootstrap", "bootout"])
    }

    private func success() -> ProcessResult {
        ProcessResult(executable: "/bin/launchctl", arguments: [], exitCode: 0, standardOutput: "", standardError: "")
    }
}

private final class ServiceExecutor: ProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessResult]
    private(set) var invocations: [[String]] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        invocations.append(arguments)
        return results.removeFirst()
    }
}
