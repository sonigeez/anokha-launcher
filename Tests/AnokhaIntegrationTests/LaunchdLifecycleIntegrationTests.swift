import AnokhaCore
import Darwin
import Foundation
import XCTest

final class LaunchdLifecycleIntegrationTests: XCTestCase {
    func testTemporaryManualAgentBootstrapRunQueryAndBootout() throws {
        guard ProcessInfo.processInfo.environment["ANOKHA_RUN_LAUNCHD_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set ANOKHA_RUN_LAUNCHD_INTEGRATION_TESTS=1 to run the real user-domain launchd test.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnokhaLaunchdIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = try locateRunner()
        let paths = AppPaths(
            applicationSupportDirectory: root.appendingPathComponent("support"),
            launchAgentsDirectory: root.appendingPathComponent("agents")
        )
        let repository = JobRepository(paths: paths)
        try repository.prepareDirectories()

        let marker = root.appendingPathComponent("launch succeeded.txt")
        let job = JobDefinition(
            name: "Integration \(UUID().uuidString)",
            command: .file(
                path: "/bin/sh",
                arguments: ["-c", "printf launched > \"$1\"", "anokha-integration", marker.path]
            ),
            activation: .manual,
            restartPolicy: .never
        )
        let configuration = try ExecutionPlanCompiler().compile(job, paths: paths)
        try repository.write(configuration: configuration)
        let document = try LaunchAgentCompiler().compile(
            job,
            runnerExecutableURL: runner,
            configurationURL: paths.configurationURL(for: job.id)
        )
        let plist = paths.launchAgentURL(for: job)
        try AtomicFile.write(document.data, to: plist, permissions: 0o600)

        let client = LaunchdClient(userID: getuid())
        var loaded = false
        defer {
            if loaded { _ = try? client.bootout(label: job.label) }
        }

        _ = try client.bootstrap(plistURL: plist)
        loaded = true
        let idle = try client.query(label: job.label)
        guard case .loaded = idle.loadState else { return XCTFail("Manual job was not loaded") }

        _ = try client.kickstart(label: job.label)
        try poll(timeout: 10) {
            FileManager.default.fileExists(atPath: marker.path)
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "launched")

        try poll(timeout: 10) {
            guard let data = try? Data(contentsOf: paths.statusURL(for: job.id)),
                  let status = try? JSONCoding.decoder().decode(RunnerStatus.self, from: data) else {
                return false
            }
            return status.state == .exited && status.lastExitCode == 0
        }

        _ = try client.bootout(label: job.label)
        loaded = false
        XCTAssertEqual(try client.query(label: job.label).loadState, .notLoaded)
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
        if let candidate = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return candidate
        }
        throw XCTSkip("Build AnokhaJobRunner first or set ANOKHA_RUNNER_PATH.")
    }

    private func poll(timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Condition was not met within \(timeout) seconds")
    }
}
