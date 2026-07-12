import Foundation

public enum ValidationSeverity: String, Codable, Sendable {
    case error
    case warning
}

public enum ValidationCode: String, Codable, Sendable {
    case emptyName
    case nameTooLong
    case emptyShellCommand
    case invalidExecutablePath
    case executableMissing
    case executableNotRegularFile
    case executableNotExecutable
    case executableWritableByOthers
    case invalidWorkingDirectory
    case invalidEnvironmentName
    case duplicateEnvironmentName
    case containsNullByte
    case invalidSchedule
    case contradictoryLifecycle
    case restartDelayTooShort
    case invalidLogPolicy
    case plaintextEnvironment
}

public struct ValidationIssue: Codable, Hashable, Identifiable, Sendable {
    public var code: ValidationCode
    public var severity: ValidationSeverity
    public var message: String
    public var field: String?

    public var id: String {
        "\(severity.rawValue):\(code.rawValue):\(field ?? ""):\(message)"
    }

    public init(code: ValidationCode, severity: ValidationSeverity, message: String, field: String? = nil) {
        self.code = code
        self.severity = severity
        self.message = message
        self.field = field
    }
}

public struct ValidationReport: Codable, Hashable, Sendable {
    public var issues: [ValidationIssue]
    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }

    public init(issues: [ValidationIssue]) {
        self.issues = issues
    }
}

public protocol FileSystemChecking: Sendable {
    func itemExists(at path: String) -> Bool
    func isDirectory(at path: String) -> Bool
    func isRegularFile(at path: String) -> Bool
    func isExecutable(at path: String) -> Bool
    func posixPermissions(at path: String) -> Int?
}

public struct LiveFileSystem: FileSystemChecking {
    public init() {}

    public func itemExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isDirectory(at path: String) -> Bool {
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    public func isRegularFile(at path: String) -> Bool {
        guard let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    public func isExecutable(at path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    public func posixPermissions(at path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }
}

public extension JobDefinition {
    func validate(fileSystem: any FileSystemChecking = LiveFileSystem()) -> ValidationReport {
        var issues: [ValidationIssue] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedName.isEmpty {
            issues.append(.init(code: .emptyName, severity: .error, message: "Give the job a name.", field: "name"))
        } else if trimmedName.count > 120 {
            issues.append(.init(code: .nameTooLong, severity: .error, message: "Job names must be 120 characters or fewer.", field: "name"))
        }

        switch command {
        case .shell(let command):
            if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(code: .emptyShellCommand, severity: .error, message: "Enter a shell command.", field: "command"))
            }
            if command.contains("\0") {
                issues.append(.init(code: .containsNullByte, severity: .error, message: "Shell commands cannot contain a null byte.", field: "command"))
            }
        case .file(let path, let arguments):
            if path.isEmpty || !path.hasPrefix("/") {
                issues.append(.init(code: .invalidExecutablePath, severity: .error, message: "Choose an executable using an absolute path.", field: "file"))
            } else if !fileSystem.itemExists(at: path) {
                issues.append(.init(code: .executableMissing, severity: .error, message: "The selected file no longer exists.", field: "file"))
            } else if !fileSystem.isRegularFile(at: path) {
                issues.append(.init(code: .executableNotRegularFile, severity: .error, message: "The selected path is not a regular file.", field: "file"))
            } else if !fileSystem.isExecutable(at: path) {
                issues.append(.init(code: .executableNotExecutable, severity: .error, message: "The selected file is not executable. Fix its permissions before enabling this job.", field: "file"))
            } else if let permissions = fileSystem.posixPermissions(at: path), permissions & 0o022 != 0 {
                issues.append(.init(code: .executableWritableByOthers, severity: .warning, message: "This executable is writable by another user or group. That makes it unsafe for unattended execution.", field: "file"))
            }

            if path.contains("\0") || arguments.contains(where: { $0.contains("\0") }) {
                issues.append(.init(code: .containsNullByte, severity: .error, message: "Executable paths and arguments cannot contain a null byte.", field: "arguments"))
            }
        }

        if let directory = workingDirectory, !directory.isEmpty {
            if !directory.hasPrefix("/") || !fileSystem.isDirectory(at: directory) {
                issues.append(.init(code: .invalidWorkingDirectory, severity: .error, message: "The working directory must be an existing folder with an absolute path.", field: "workingDirectory"))
            }
        }

        let environmentPattern = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
        var seenKeys: Set<String> = []
        for variable in environment {
            let range = NSRange(variable.key.startIndex..<variable.key.endIndex, in: variable.key)
            if environmentPattern.firstMatch(in: variable.key, range: range) == nil {
                issues.append(.init(code: .invalidEnvironmentName, severity: .error, message: "‘\(variable.key)’ is not a valid environment variable name.", field: "environment.\(variable.id)"))
            }
            if !seenKeys.insert(variable.key).inserted {
                issues.append(.init(code: .duplicateEnvironmentName, severity: .error, message: "Environment variable ‘\(variable.key)’ is defined more than once.", field: "environment.\(variable.id)"))
            }
            if variable.key.contains("\0") || variable.value.contains("\0") {
                issues.append(.init(code: .containsNullByte, severity: .error, message: "Environment names and values cannot contain a null byte.", field: "environment.\(variable.id)"))
            }
        }

        if !environment.isEmpty {
            issues.append(.init(code: .plaintextEnvironment, severity: .warning, message: "Environment values are stored as plaintext. Do not put passwords, tokens, or secrets here.", field: "environment"))
        }

        issues.append(contentsOf: activation.validationIssues)

        switch activation {
        case .manual where restartPolicy != .never:
            issues.append(.init(code: .contradictoryLifecycle, severity: .error, message: "Manual-only jobs cannot restart automatically.", field: "restartPolicy"))
        case .keepRunning where restartPolicy != .always:
            issues.append(.init(code: .contradictoryLifecycle, severity: .error, message: "Keep-running jobs must use Always keep running.", field: "restartPolicy"))
        case .atLogin where restartPolicy == .always:
            issues.append(.init(code: .contradictoryLifecycle, severity: .error, message: "Choose Keep running instead of combining this trigger with Always keep running.", field: "restartPolicy"))
        case .scheduled where restartPolicy == .always:
            issues.append(.init(code: .contradictoryLifecycle, severity: .error, message: "Choose Keep running instead of combining this trigger with Always keep running.", field: "restartPolicy"))
        default:
            break
        }

        if restartPolicy != .never, restartDelaySeconds < 10 {
            issues.append(.init(code: .restartDelayTooShort, severity: .error, message: "Restart delay must be at least 10 seconds.", field: "restartDelay"))
        }

        if logPolicy.maxBytesPerFile < 1_024 || logPolicy.retainedBackups < 0 || logPolicy.retainedBackups > 10 {
            issues.append(.init(code: .invalidLogPolicy, severity: .error, message: "The log retention policy is invalid.", field: "logs"))
        }

        return ValidationReport(issues: issues)
    }
}

private extension JobActivation {
    var validationIssues: [ValidationIssue] {
        guard case .scheduled(let schedule) = self else { return [] }

        let validTime: (Int, Int) -> Bool = { (0...23).contains($0) && (0...59).contains($1) }
        let valid: Bool
        switch schedule {
        case .hourly(let minute):
            valid = (0...59).contains(minute)
        case .daily(let hour, let minute):
            valid = validTime(hour, minute)
        case .weekdays(let days, let hour, let minute):
            valid = !days.isEmpty && validTime(hour, minute)
        case .monthly(let day, let hour, let minute):
            valid = (1...31).contains(day) && validTime(hour, minute)
        case .interval(let hours, let minutes):
            valid = hours >= 0 && minutes >= 0 && minutes < 60 && (hours > 0 || minutes > 0)
        }

        return valid ? [] : [
            .init(code: .invalidSchedule, severity: .error, message: "Choose a valid schedule.", field: "schedule")
        ]
    }
}
