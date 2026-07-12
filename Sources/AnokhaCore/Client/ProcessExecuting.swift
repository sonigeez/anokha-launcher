import Darwin
import Dispatch
import Foundation

public struct ProcessResult: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(executable: String, arguments: [String], exitCode: Int32, standardOutput: String, standardError: String) {
        self.executable = executable
        self.arguments = arguments
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol ProcessExecuting: Sendable {
    func run(executable: URL, arguments: [String]) throws -> ProcessResult
}

public enum ProcessExecutionError: LocalizedError {
    case timedOut(executable: String, arguments: [String], seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let arguments, let seconds):
            return "\(executable) \(arguments.joined(separator: " ")) did not finish within \(Int(seconds)) seconds."
        }
    }
}

public struct FoundationProcessExecutor: ProcessExecuting {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let outputCapture = ProcessOutputCapture()
        let errorCapture = ProcessOutputCapture()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputCapture.data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorCapture.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            readers.wait()
            throw ProcessExecutionError.timedOut(
                executable: executable.path,
                arguments: arguments,
                seconds: timeout
            )
        }
        process.waitUntilExit()
        readers.wait()

        return ProcessResult(
            executable: executable.path,
            arguments: arguments,
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputCapture.data, as: UTF8.self),
            standardError: String(decoding: errorCapture.data, as: UTF8.self)
        )
    }
}

private final class ProcessOutputCapture: @unchecked Sendable {
    var data = Data()
}
