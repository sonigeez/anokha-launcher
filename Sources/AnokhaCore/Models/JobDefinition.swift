import Foundation

public struct JobDefinition: Codable, Hashable, Identifiable, Sendable {
    public static let labelNamespace = "com.anokha.launcher.job"
    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public var id: UUID
    public var name: String
    public var command: JobCommand
    public var workingDirectory: String?
    public var activation: JobActivation
    public var restartPolicy: RestartPolicy
    public var restartDelaySeconds: Int
    public var environment: [EnvironmentVariable]
    public var logPolicy: LogPolicy

    public var label: String {
        "\(Self.labelNamespace).\(id.uuidString.lowercased())"
    }

    public init(
        id: UUID = UUID(),
        name: String,
        command: JobCommand,
        workingDirectory: String? = nil,
        activation: JobActivation = .atLogin,
        restartPolicy: RestartPolicy = .never,
        restartDelaySeconds: Int = 10,
        environment: [EnvironmentVariable] = [],
        logPolicy: LogPolicy = .default
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.activation = activation
        self.restartPolicy = restartPolicy
        self.restartDelaySeconds = restartDelaySeconds
        self.environment = environment
        self.logPolicy = logPolicy
    }

    public static func newDraft() -> JobDefinition {
        JobDefinition(name: "Untitled Job", command: .shell(command: ""))
    }

    public var policySummary: String {
        switch (activation, restartPolicy) {
        case (.keepRunning, _), (_, .always):
            return "Always running"
        case (_, .onFailure):
            return "\(activation.summary), restart on failure"
        default:
            return activation.summary
        }
    }

    public var executionSummary: String {
        switch command {
        case .shell(let command):
            return "/bin/zsh -lc \(Self.quoteForDisplay(command))"
        case .file(let path, let arguments):
            return ([path] + arguments).map(Self.quoteForDisplay).joined(separator: " ")
        }
    }

    private static func quoteForDisplay(_ value: String) -> String {
        if !value.isEmpty,
           value.unicodeScalars.allSatisfy({ scalar in
               CharacterSet.alphanumerics.contains(scalar) || "-._/:".unicodeScalars.contains(scalar)
           }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public enum JobCommand: Codable, Hashable, Sendable {
    case shell(command: String)
    case file(path: String, arguments: [String])

    public var kind: JobCommandKind {
        switch self {
        case .shell: return .shell
        case .file: return .file
        }
    }
}

public enum JobCommandKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case shell
    case file

    public var id: String { rawValue }
    public var title: String { self == .shell ? "Shell Command" : "File" }
}

public enum JobActivation: Codable, Hashable, Sendable {
    case atLogin
    case scheduled(JobSchedule)
    case keepRunning
    case manual

    public var kind: JobActivationKind {
        switch self {
        case .atLogin: return .atLogin
        case .scheduled: return .scheduled
        case .keepRunning: return .keepRunning
        case .manual: return .manual
        }
    }

    public var summary: String {
        switch self {
        case .atLogin: return "At login"
        case .scheduled(let schedule): return schedule.summary
        case .keepRunning: return "Always running"
        case .manual: return "Manual only"
        }
    }
}

public enum JobActivationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case atLogin
    case scheduled
    case keepRunning
    case manual

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .atLogin: return "At login"
        case .scheduled: return "On a schedule"
        case .keepRunning: return "Keep running"
        case .manual: return "Manual only"
        }
    }
}

public enum RestartPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case never
    case onFailure
    case always

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .never: return "Do not restart"
        case .onFailure: return "Restart only after failure"
        case .always: return "Always keep running"
        }
    }
}

public struct EnvironmentVariable: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

public struct LogPolicy: Codable, Hashable, Sendable {
    public var maxBytesPerFile: Int
    public var retainedBackups: Int

    public init(maxBytesPerFile: Int, retainedBackups: Int) {
        self.maxBytesPerFile = maxBytesPerFile
        self.retainedBackups = retainedBackups
    }

    public static let `default` = LogPolicy(
        maxBytesPerFile: 5 * 1_024 * 1_024,
        retainedBackups: 1
    )

    public var maximumTotalBytes: Int {
        maxBytesPerFile * (retainedBackups + 1) * 2
    }
}

public struct ManagedJobRecord: Codable, Hashable, Identifiable, Sendable {
    public var definition: JobDefinition
    public var enabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int
    public var installedFingerprint: String?
    public var installedConfigurationFingerprint: String?

    public var id: UUID { definition.id }

    public init(
        definition: JobDefinition,
        enabled: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int = 1,
        installedFingerprint: String? = nil,
        installedConfigurationFingerprint: String? = nil
    ) {
        self.definition = definition
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.installedFingerprint = installedFingerprint
        self.installedConfigurationFingerprint = installedConfigurationFingerprint
    }
}
