import AnokhaCore
import Foundation
import XCTest

final class RepositoryAndLogTests: XCTestCase {
    func testAtomicWriteAppliesPrivateModeBeforePublication() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("private.json")
        try AtomicFile.write(Data("secret-ish".utf8), to: url, permissions: 0o600)
        let permissions = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(permissions & 0o777, 0o600)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: base.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    func testSemanticFingerprintIgnoresFormattingButDetectsMeaningfulChange() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(
            applicationSupportDirectory: base.appendingPathComponent("support"),
            launchAgentsDirectory: base.appendingPathComponent("agents")
        )
        let repository = JobRepository(paths: paths)
        try repository.prepareDirectories()
        let job = JobDefinition.validShell()
        let document = try LaunchAgentCompiler().compile(
            job,
            runnerExecutableURL: URL(fileURLWithPath: "/tmp/runner"),
            configurationURL: URL(fileURLWithPath: "/tmp/config"),
            fileSystem: StubFileSystem()
        )
        let plistURL = paths.launchAgentURL(for: job)
        try AtomicFile.write(document.data, to: plistURL)
        try repository.write(configuration: ExecutionPlanCompiler().compile(job, paths: paths, fileSystem: StubFileSystem()))
        let record = ManagedJobRecord(
            definition: job,
            enabled: true,
            installedFingerprint: document.fingerprint,
            installedConfigurationFingerprint: try repository.configurationFingerprint(id: job.id)
        )
        XCTAssertEqual(repository.reconcile(record), .inSync)

        var reformatted = String(decoding: document.data, as: UTF8.self)
        reformatted = reformatted.replacingOccurrences(of: "<dict>", with: "<dict>\n\n")
        try AtomicFile.write(Data(reformatted.utf8), to: plistURL)
        XCTAssertEqual(repository.reconcile(record), .inSync)

        let changed = reformatted.replacingOccurrences(of: job.label, with: job.label + ".changed")
        try AtomicFile.write(Data(changed.utf8), to: plistURL)
        guard case .externallyModified = repository.reconcile(record) else {
            return XCTFail("Expected an external modification conflict")
        }
    }

    func testExecutionConfigurationChangesAreConflicts() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(
            applicationSupportDirectory: base.appendingPathComponent("support"),
            launchAgentsDirectory: base.appendingPathComponent("agents")
        )
        let repository = JobRepository(paths: paths)
        try repository.prepareDirectories()
        let job = JobDefinition.validShell()
        let document = try LaunchAgentCompiler().compile(
            job,
            runnerExecutableURL: paths.runnerExecutableURL,
            configurationURL: paths.configurationURL(for: job.id),
            fileSystem: StubFileSystem()
        )
        try AtomicFile.write(document.data, to: paths.launchAgentURL(for: job))
        var configuration = try ExecutionPlanCompiler().compile(job, paths: paths, fileSystem: StubFileSystem())
        try repository.write(configuration: configuration)
        let record = ManagedJobRecord(
            definition: job,
            enabled: true,
            installedFingerprint: document.fingerprint,
            installedConfigurationFingerprint: try repository.configurationFingerprint(id: job.id)
        )
        XCTAssertEqual(repository.reconcile(record), .inSync)

        configuration.command = .shell(command: "echo externally changed")
        try repository.write(configuration: configuration)
        guard case .externallyModifiedConfiguration = repository.reconcile(record) else {
            return XCTFail("Expected an execution-configuration conflict")
        }
    }

    func testMissingEnabledPlistIsConflict() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(applicationSupportDirectory: base, launchAgentsDirectory: base.appendingPathComponent("agents"))
        let repository = JobRepository(paths: paths)
        let record = ManagedJobRecord(definition: .validShell(), enabled: true, installedFingerprint: "expected")
        XCTAssertEqual(repository.reconcile(record), .missingInstalledFile)
    }

    func testRollingWriterEnforcesHardBound() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("stdout.log")
        let writer = try RollingLogWriter(url: url, maxBytes: 1_024, backupCount: 1)
        for index in 0..<20 {
            try writer.append(Data(String(repeating: "\(index % 10)", count: 300).utf8))
        }
        let current = (try? Data(contentsOf: url).count) ?? 0
        let backup = (try? Data(contentsOf: URL(fileURLWithPath: url.path + ".1")).count) ?? 0
        XCTAssertLessThanOrEqual(current, 1_024)
        XCTAssertLessThanOrEqual(backup, 1_024)
        XCTAssertLessThanOrEqual(current + backup, 2_048)
    }

    func testClearTruncatesCurrentLogAndRemovesBackup() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(applicationSupportDirectory: base, launchAgentsDirectory: base.appendingPathComponent("agents"))
        let job = JobDefinition.validShell()
        try AtomicFile.write(Data("current".utf8), to: paths.standardOutputURL(for: job.id))
        try AtomicFile.write(Data("backup".utf8), to: URL(fileURLWithPath: paths.standardOutputURL(for: job.id).path + ".1"))
        try LogService(paths: paths).clear(job: job, stream: .standardOutput)
        XCTAssertEqual(try Data(contentsOf: paths.standardOutputURL(for: job.id)).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.standardOutputURL(for: job.id).path + ".1"))
    }

    func testLogReaderLoadsOnlyRequestedTailButReportsFullSize() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(applicationSupportDirectory: base, launchAgentsDirectory: base.appendingPathComponent("agents"))
        let job = JobDefinition.validShell()
        let current = paths.standardOutputURL(for: job.id)
        try AtomicFile.write(Data("current8".utf8), to: current)
        try AtomicFile.write(Data("backup08".utf8), to: URL(fileURLWithPath: current.path + ".1"))

        let content = LogService(paths: paths).read(
            job: job,
            stream: .standardOutput,
            maxBytes: 10
        )
        XCTAssertEqual(content.text, "08current8")
        XCTAssertEqual(content.byteCount, 16)
    }

    func testLogReaderSupportsZeroBackups() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(applicationSupportDirectory: base, launchAgentsDirectory: base.appendingPathComponent("agents"))
        var job = JobDefinition.validShell()
        job.logPolicy = LogPolicy(maxBytesPerFile: 1_024, retainedBackups: 0)
        try AtomicFile.write(Data("only-current".utf8), to: paths.standardOutputURL(for: job.id))
        let content = LogService(paths: paths).read(job: job, stream: .standardOutput)
        XCTAssertEqual(content.text, "only-current")
    }
}
