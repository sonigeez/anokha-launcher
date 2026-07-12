import Darwin
import Dispatch
import Foundation

public struct ChildTermination: Equatable, Sendable {
    public var exitCode: Int32
    public var signal: Int32?

    public init(exitCode: Int32, signal: Int32? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }
}

public final class JobRunnerEngine: @unchecked Sendable {
    private let configuration: RunnerConfiguration
    private let outputWriter: RollingLogWriter
    private let errorWriter: RollingLogWriter
    private let signals = RunnerSignalCoordinator()

    public init(configuration: RunnerConfiguration) throws {
        guard configuration.version == RunnerConfiguration.currentVersion else {
            throw JobConfigurationError.unsupportedConfigurationVersion(configuration.version)
        }
        self.configuration = configuration
        self.outputWriter = try RollingLogWriter(
            url: URL(fileURLWithPath: configuration.standardOutputPath),
            maxBytes: configuration.logPolicy.maxBytesPerFile,
            backupCount: configuration.logPolicy.retainedBackups
        )
        self.errorWriter = try RollingLogWriter(
            url: URL(fileURLWithPath: configuration.standardErrorPath),
            maxBytes: configuration.logPolicy.maxBytesPerFile,
            backupCount: configuration.logPolicy.retainedBackups
        )
    }

    public func run() -> Int32 {
        signals.start()
        defer { signals.stop() }

        var status = RunnerStatus(
            jobID: configuration.jobID,
            state: .starting,
            runnerPID: getpid()
        )
        write(status)

        while !signals.shouldTerminate {
            status.state = .starting
            status.message = nil
            write(status)

            do {
                let (termination, childPID, startedAt) = try runChild(status: &status)
                status.childPID = nil
                status.lastStartedAt = startedAt
                status.lastExitedAt = Date()
                status.lastExitCode = termination.exitCode
                status.lastTerminationSignal = termination.signal
                status.runCount += 1
                if termination.exitCode == 0 {
                    status.consecutiveFailures = 0
                } else {
                    status.consecutiveFailures += 1
                }

                if signals.shouldTerminate {
                    status.state = .exited
                    status.message = "Stopped by request."
                    write(status)
                    return 0
                }

                switch configuration.restartPolicy {
                case .never:
                    status.state = .exited
                    write(status)
                    return termination.exitCode
                case .onFailure where termination.exitCode == 0:
                    status.state = .exited
                    write(status)
                    return 0
                case .onFailure, .always:
                    status.state = .waitingToRestart
                    status.message = "Restarting in at least \(configuration.restartDelaySeconds) seconds."
                    write(status)
                    if !signals.wait(seconds: configuration.restartDelaySeconds) {
                        status.state = .exited
                        status.message = "Stopped while waiting to restart."
                        write(status)
                        return 0
                    }
                }

                _ = childPID // retained in the tuple for clear lifecycle diagnostics.
            } catch {
                status.childPID = nil
                status.state = .failedToLaunch
                status.lastExitedAt = Date()
                status.lastExitCode = 127
                status.lastTerminationSignal = nil
                status.runCount += 1
                status.consecutiveFailures += 1
                status.message = error.localizedDescription
                write(status)
                try? errorWriter.append(Data("AnokhaJobRunner: \(error.localizedDescription)\n".utf8))

                if configuration.restartPolicy == .never || signals.shouldTerminate {
                    return 127
                }
                status.state = .waitingToRestart
                write(status)
                if !signals.wait(seconds: configuration.restartDelaySeconds) { return 0 }
            }
        }

        return 0
    }

    private func runChild(status: inout RunnerStatus) throws -> (ChildTermination, pid_t, Date) {
        let command = commandVector()
        let environment = environmentVector()
        let child = try SpawnedChild.start(
            executable: command.executable,
            arguments: command.arguments,
            environment: environment,
            workingDirectory: configuration.workingDirectory
        )
        signals.setChildProcessGroup(child.pid)
        defer { signals.setChildProcessGroup(nil) }

        let startedAt = Date()
        status.state = .running
        status.childPID = child.pid
        status.lastStartedAt = startedAt
        status.message = nil
        write(status)

        let outputGroup = DispatchGroup()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async { [outputWriter] in
            child.drainOutput(to: outputWriter)
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async { [errorWriter] in
            child.drainError(to: errorWriter)
            outputGroup.leave()
        }

        let termination = child.wait()
        outputGroup.wait()
        return (termination, child.pid, startedAt)
    }

    private func commandVector() -> (executable: String, arguments: [String]) {
        switch configuration.command {
        case .shell(let command):
            return ("/bin/zsh", ["/bin/zsh", "-lc", command])
        case .file(let path, let arguments):
            return (path, [path] + arguments)
        }
    }

    private func environmentVector() -> [String: String] {
        var values = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LOGNAME": NSUserName(),
            "SHELL": "/bin/zsh",
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName()
        ]
        for (key, value) in configuration.environment {
            values[key] = value
        }
        return values
    }

    private func write(_ status: RunnerStatus) {
        guard let data = try? JSONCoding.encoder().encode(status) else { return }
        try? AtomicFile.write(data, to: URL(fileURLWithPath: configuration.statusPath), permissions: 0o600)
    }
}

private enum SpawnError: LocalizedError {
    case pipe(Int32)
    case fileActions(Int32)
    case attributes(Int32)
    case spawn(Int32, String)
    case invalidWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .pipe(let code): return "Could not create output pipe: \(String(cString: strerror(code)))."
        case .fileActions(let code): return "Could not configure child file descriptors: \(String(cString: strerror(code)))."
        case .attributes(let code): return "Could not configure child process group: \(String(cString: strerror(code)))."
        case .spawn(let code, let executable): return "Could not launch \(executable): \(String(cString: strerror(code)))."
        case .invalidWorkingDirectory(let path): return "Working directory is unavailable: \(path)."
        }
    }
}

private final class SpawnedChild: @unchecked Sendable {
    let pid: pid_t
    private let outputHandle: FileHandle
    private let errorHandle: FileHandle

    private init(pid: pid_t, outputFD: Int32, errorFD: Int32) {
        self.pid = pid
        self.outputHandle = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        self.errorHandle = FileHandle(fileDescriptor: errorFD, closeOnDealloc: true)
    }

    static func start(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws -> SpawnedChild {
        guard FileManager.default.fileExists(atPath: workingDirectory) else {
            throw SpawnError.invalidWorkingDirectory(workingDirectory)
        }

        var outputPipe: [Int32] = [0, 0]
        var errorPipe: [Int32] = [0, 0]
        guard Darwin.pipe(&outputPipe) == 0 else { throw SpawnError.pipe(errno) }
        guard Darwin.pipe(&errorPipe) == 0 else {
            Darwin.close(outputPipe[0]); Darwin.close(outputPipe[1])
            throw SpawnError.pipe(errno)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var actionsInitialized = false
        var attributesInitialized = false

        defer {
            if actionsInitialized { posix_spawn_file_actions_destroy(&fileActions) }
            if attributesInitialized { posix_spawnattr_destroy(&attributes) }
        }

        var code = posix_spawn_file_actions_init(&fileActions)
        guard code == 0 else {
            closePipes(outputPipe, errorPipe)
            throw SpawnError.fileActions(code)
        }
        actionsInitialized = true

        code = posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO)
        guard code == 0 else { closePipes(outputPipe, errorPipe); throw SpawnError.fileActions(code) }
        code = posix_spawn_file_actions_adddup2(&fileActions, errorPipe[1], STDERR_FILENO)
        guard code == 0 else { closePipes(outputPipe, errorPipe); throw SpawnError.fileActions(code) }
        posix_spawn_file_actions_addclose(&fileActions, outputPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, outputPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errorPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errorPipe[1])
        code = posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
        guard code == 0 else { closePipes(outputPipe, errorPipe); throw SpawnError.fileActions(code) }

        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { closePipes(outputPipe, errorPipe); throw SpawnError.attributes(code) }
        attributesInitialized = true
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGHUP)
        code = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard code == 0 else { closePipes(outputPipe, errorPipe); throw SpawnError.attributes(code) }

        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        code = posix_spawnattr_setsigmask(&attributes, &signalMask)
        guard code == 0 else { closePipes(outputPipe, errorPipe); throw SpawnError.attributes(code) }

        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        code = posix_spawnattr_setflags(&attributes, flags)
        guard code == 0 else { closePipes(outputPipe, errorPipe); throw SpawnError.attributes(code) }
        code = posix_spawnattr_setpgroup(&attributes, 0)
        guard code == 0 else { closePipes(outputPipe, errorPipe); throw SpawnError.attributes(code) }

        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }

        var childPID: pid_t = 0
        code = executable.withCString { executablePointer in
            posix_spawn(&childPID, executablePointer, &fileActions, &attributes, &argv, &envp)
        }
        guard code == 0 else {
            closePipes(outputPipe, errorPipe)
            throw SpawnError.spawn(code, executable)
        }

        Darwin.close(outputPipe[1])
        Darwin.close(errorPipe[1])
        return SpawnedChild(pid: childPID, outputFD: outputPipe[0], errorFD: errorPipe[0])
    }

    func drainOutput(to writer: RollingLogWriter) {
        drain(outputHandle, to: writer)
    }

    func drainError(to writer: RollingLogWriter) {
        drain(errorHandle, to: writer)
    }

    func wait() -> ChildTermination {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        if status & 0x7f == 0 {
            return ChildTermination(exitCode: (status >> 8) & 0xff)
        }
        let signal = status & 0x7f
        return ChildTermination(exitCode: 128 + signal, signal: signal)
    }

    private func drain(_ handle: FileHandle, to writer: RollingLogWriter) {
        while true {
            do {
                guard let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty else { break }
                try writer.append(data)
            } catch {
                break
            }
        }
        try? handle.close()
    }

    private static func closePipes(_ output: [Int32], _ error: [Int32]) {
        output.forEach { Darwin.close($0) }
        error.forEach { Darwin.close($0) }
    }
}

private final class RunnerSignalCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var childProcessGroup: pid_t?
    private var terminationRequested = false
    private var requestedSignal: Int32 = SIGTERM
    private var sources: [DispatchSourceSignal] = []

    var shouldTerminate: Bool {
        lock.withLock { terminationRequested }
    }

    func start() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                self?.requestTermination(signal: signalNumber)
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    func setChildProcessGroup(_ pid: pid_t?) {
        let pendingSignal = lock.withLock { () -> Int32? in
            childProcessGroup = pid
            guard pid != nil, terminationRequested else { return nil }
            return requestedSignal
        }
        // Close the race where launchd stops the runner between spawn and the
        // child process group becoming visible to the signal coordinator.
        if let pid, let pendingSignal {
            Darwin.kill(-pid, pendingSignal)
        }
    }

    func wait(seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, seconds)))
        while Date() < deadline {
            if shouldTerminate { return false }
            Thread.sleep(forTimeInterval: min(0.1, deadline.timeIntervalSinceNow))
        }
        return !shouldTerminate
    }

    private func requestTermination(signal signalNumber: Int32) {
        let group = lock.withLock { () -> pid_t? in
            terminationRequested = true
            requestedSignal = signalNumber
            return childProcessGroup
        }
        if let group {
            Darwin.kill(-group, signalNumber)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                let stillRunning = self.lock.withLock {
                    self.terminationRequested && self.childProcessGroup == group
                }
                if stillRunning { Darwin.kill(-group, SIGKILL) }
            }
        }
    }
}
