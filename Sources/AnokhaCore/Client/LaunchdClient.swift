import Darwin
import Foundation

public struct LaunchdSnapshot: Equatable, Sendable {
    public enum LoadState: Equatable, Sendable {
        case notLoaded
        case loaded(state: String?)
    }

    public var loadState: LoadState
    public var processID: Int32?
    public var lastExitCode: Int32?
    public var rawOutput: String

    public init(loadState: LoadState, processID: Int32? = nil, lastExitCode: Int32? = nil, rawOutput: String = "") {
        self.loadState = loadState
        self.processID = processID
        self.lastExitCode = lastExitCode
        self.rawOutput = rawOutput
    }
}

public enum LaunchdClientError: LocalizedError {
    case commandFailed(ProcessResult)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let result):
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "launchctl exited with status \(result.exitCode)."
                : "launchctl exited with status \(result.exitCode): \(detail)"
        }
    }
}

public struct LaunchdClient: Sendable {
    public let userID: uid_t
    public let executor: any ProcessExecuting
    public let executableURL: URL

    public init(
        userID: uid_t = getuid(),
        executor: any ProcessExecuting = FoundationProcessExecutor(),
        executableURL: URL = URL(fileURLWithPath: "/bin/launchctl")
    ) {
        self.userID = userID
        self.executor = executor
        self.executableURL = executableURL
    }

    public var domainTarget: String { "gui/\(userID)" }
    public func serviceTarget(label: String) -> String { "\(domainTarget)/\(label)" }

    @discardableResult
    public func bootstrap(plistURL: URL) throws -> ProcessResult {
        try checked(["bootstrap", domainTarget, plistURL.path])
    }

    @discardableResult
    public func bootout(label: String, ignoreMissing: Bool = true) throws -> ProcessResult {
        let result = try executor.run(executable: executableURL, arguments: ["bootout", serviceTarget(label: label)])
        if result.exitCode != 0 && !(ignoreMissing && isMissingService(result)) {
            throw LaunchdClientError.commandFailed(result)
        }
        return result
    }

    @discardableResult
    public func kickstart(label: String, restartIfRunning: Bool = false) throws -> ProcessResult {
        let flag = restartIfRunning ? "-kp" : "-p"
        return try checked(["kickstart", flag, serviceTarget(label: label)])
    }

    @discardableResult
    public func terminate(label: String) throws -> ProcessResult {
        try checked(["kill", "SIGTERM", serviceTarget(label: label)])
    }

    public func query(label: String) throws -> LaunchdSnapshot {
        let result = try executor.run(executable: executableURL, arguments: ["print", serviceTarget(label: label)])
        guard result.exitCode == 0 else {
            if isMissingService(result) {
                return LaunchdSnapshot(loadState: .notLoaded, rawOutput: result.standardError)
            }
            throw LaunchdClientError.commandFailed(result)
        }

        // launchctl explicitly labels print output unstable. Keep this parser best-effort.
        let state = capture(#"(?m)^\s*state\s*=\s*([^\n]+)"#, in: result.standardOutput)
        let pid = capture(#"(?m)^\s*pid\s*=\s*(\d+)"#, in: result.standardOutput).flatMap(Int32.init)
        let exitCode = capture(#"(?m)^\s*last exit code\s*=\s*(-?\d+)"#, in: result.standardOutput).flatMap(Int32.init)
        return LaunchdSnapshot(
            loadState: .loaded(state: state?.trimmingCharacters(in: .whitespaces)),
            processID: pid,
            lastExitCode: exitCode,
            rawOutput: result.standardOutput
        )
    }

    private func checked(_ arguments: [String]) throws -> ProcessResult {
        let result = try executor.run(executable: executableURL, arguments: arguments)
        guard result.exitCode == 0 else { throw LaunchdClientError.commandFailed(result) }
        return result
    }

    private func isMissingService(_ result: ProcessResult) -> Bool {
        let combined = (result.standardOutput + "\n" + result.standardError).lowercased()
        return combined.contains("could not find service")
            || combined.contains("no such process")
            || combined.contains("service cannot be found")
            || combined.contains("errno 3")
    }

    private func capture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range])
    }
}
