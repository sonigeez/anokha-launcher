import AnokhaCore
import Foundation
import XCTest

final class LaunchdClientTests: XCTestCase {
    func testUsesExactModernGuiDomainCommands() throws {
        let executor = RecordingExecutor(results: [
            ProcessResult(executable: "/bin/launchctl", arguments: [], exitCode: 0, standardOutput: "", standardError: ""),
            ProcessResult(executable: "/bin/launchctl", arguments: [], exitCode: 0, standardOutput: "123\n", standardError: ""),
            ProcessResult(executable: "/bin/launchctl", arguments: [], exitCode: 0, standardOutput: "", standardError: "")
        ])
        let client = LaunchdClient(userID: 501, executor: executor)
        _ = try client.bootstrap(plistURL: URL(fileURLWithPath: "/tmp/job.plist"))
        _ = try client.kickstart(label: "com.example.job")
        _ = try client.bootout(label: "com.example.job")
        XCTAssertEqual(executor.invocations, [
            ["bootstrap", "gui/501", "/tmp/job.plist"],
            ["kickstart", "-p", "gui/501/com.example.job"],
            ["bootout", "gui/501/com.example.job"]
        ])
    }

    func testBestEffortPrintParserDegradesToOptionalFields() throws {
        let output = """
        gui/501/com.example.job = {
            state = running
            pid = 1234
            last exit code = 42
        }
        """
        let executor = RecordingExecutor(results: [
            ProcessResult(executable: "/bin/launchctl", arguments: [], exitCode: 0, standardOutput: output, standardError: "")
        ])
        let snapshot = try LaunchdClient(userID: 501, executor: executor).query(label: "com.example.job")
        XCTAssertEqual(snapshot.loadState, .loaded(state: "running"))
        XCTAssertEqual(snapshot.processID, 1234)
        XCTAssertEqual(snapshot.lastExitCode, 42)
    }

    func testFoundationExecutorDrainsLargeOutputWithoutDeadlock() throws {
        let result = try FoundationProcessExecutor(timeout: 5).run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1024", "count=1024"]
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.utf8.count, 1_024 * 1_024)
    }

    func testFoundationExecutorTimesOutHungProcess() {
        XCTAssertThrowsError(try FoundationProcessExecutor(timeout: 0.1).run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"]
        )) { error in
            guard case ProcessExecutionError.timedOut = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }
    }
}

private final class RecordingExecutor: ProcessExecuting, @unchecked Sendable {
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
