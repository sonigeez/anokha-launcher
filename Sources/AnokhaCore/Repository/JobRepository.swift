import CryptoKit
import Foundation

public enum JobReconciliation: Equatable, Sendable {
    case inSync
    case missingInstalledFile
    case externallyModified(expected: String, actual: String)
    case unexpectedInstalledFile(actual: String)
    case unreadableInstalledFile(String)
    case missingExecutionConfiguration
    case externallyModifiedConfiguration(expected: String, actual: String)
    case unreadableExecutionConfiguration(String)

    public var isConflict: Bool {
        self != .inSync
    }

    public var concernsExecutionConfiguration: Bool {
        switch self {
        case .missingExecutionConfiguration, .externallyModifiedConfiguration, .unreadableExecutionConfiguration:
            return true
        default:
            return false
        }
    }

    public var supportsPlistAdoption: Bool {
        switch self {
        case .externallyModified, .unexpectedInstalledFile:
            return true
        default:
            return false
        }
    }

    public var summary: String {
        switch self {
        case .inSync:
            return "Configuration is in sync."
        case .missingInstalledFile:
            return "The installed LaunchAgent was deleted outside the app."
        case .externallyModified:
            return "The installed LaunchAgent was changed outside the app."
        case .unexpectedInstalledFile:
            return "A LaunchAgent exists for this disabled job."
        case .unreadableInstalledFile(let message):
            return "The installed LaunchAgent cannot be inspected: \(message)"
        case .missingExecutionConfiguration:
            return "The enabled job's execution configuration was deleted outside the app."
        case .externallyModifiedConfiguration:
            return "The enabled job's execution configuration was changed outside the app."
        case .unreadableExecutionConfiguration(let message):
            return "The enabled job's execution configuration cannot be inspected: \(message)"
        }
    }
}

public enum JobRepositoryError: LocalizedError {
    case unexpectedSymbolicLink(URL)
    case recordNotFound(UUID)
    case revisionConflict(expected: Int, actual: Int)
    case externalConflict(JobReconciliation)

    public var errorDescription: String? {
        switch self {
        case .unexpectedSymbolicLink(let url):
            return "Refusing to follow an unexpected symbolic link at \(url.path)."
        case .recordNotFound(let id):
            return "No managed job exists with id \(id.uuidString)."
        case .revisionConflict(let expected, let actual):
            return "This job changed while it was being edited (expected revision \(expected), found \(actual))."
        case .externalConflict(let conflict):
            return conflict.summary
        }
    }
}

public final class JobRepository: @unchecked Sendable {
    public let paths: AppPaths
    private let lock = NSRecursiveLock()

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func prepareDirectories() throws {
        try lock.withLock {
            let directories = [
                paths.applicationSupportDirectory,
                paths.runnerExecutableURL.deletingLastPathComponent(),
                paths.applicationSupportDirectory.appendingPathComponent("configurations", isDirectory: true),
                paths.applicationSupportDirectory.appendingPathComponent("status", isDirectory: true),
                paths.applicationSupportDirectory.appendingPathComponent("logs", isDirectory: true),
                paths.launchAgentsDirectory
            ]
            for directory in directories {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
    }

    public func loadRecords() throws -> [ManagedJobRecord] {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: paths.recordsURL.path) else { return [] }
            let data = try Data(contentsOf: paths.recordsURL)
            return try JSONCoding.decoder().decode([ManagedJobRecord].self, from: data)
        }
    }

    public func record(id: UUID) throws -> ManagedJobRecord {
        guard let record = try loadRecords().first(where: { $0.id == id }) else {
            throw JobRepositoryError.recordNotFound(id)
        }
        return record
    }

    public func upsert(_ record: ManagedJobRecord, expectedRevision: Int? = nil) throws {
        try lock.withLock {
            var records = try loadRecords()
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                if let expectedRevision, records[index].revision != expectedRevision {
                    throw JobRepositoryError.revisionConflict(expected: expectedRevision, actual: records[index].revision)
                }
                records[index] = record
            } else {
                records.append(record)
            }
            records.sort { $0.createdAt < $1.createdAt }
            try persist(records)
        }
    }

    public func removeRecord(id: UUID) throws {
        try lock.withLock {
            var records = try loadRecords()
            guard records.contains(where: { $0.id == id }) else {
                throw JobRepositoryError.recordNotFound(id)
            }
            records.removeAll { $0.id == id }
            try persist(records)
        }
    }

    public func write(configuration: RunnerConfiguration) throws {
        let data = try JSONCoding.encoder().encode(configuration)
        try AtomicFile.write(data, to: paths.configurationURL(for: configuration.jobID), permissions: 0o600)
    }

    public func readConfiguration(id: UUID) throws -> RunnerConfiguration {
        let data = try Data(contentsOf: paths.configurationURL(for: id))
        return try JSONCoding.decoder().decode(RunnerConfiguration.self, from: data)
    }

    public func readRunnerStatus(id: UUID) -> RunnerStatus? {
        guard let data = try? Data(contentsOf: paths.statusURL(for: id)) else { return nil }
        return try? JSONCoding.decoder().decode(RunnerStatus.self, from: data)
    }

    public func reconcile(_ record: ManagedJobRecord) -> JobReconciliation {
        let url = paths.launchAgentURL(for: record.definition)
        let exists = FileManager.default.fileExists(atPath: url.path)

        if !record.enabled {
            guard exists else { return .inSync }
            do {
                return .unexpectedInstalledFile(actual: try fingerprint(at: url))
            } catch {
                return .unreadableInstalledFile(error.localizedDescription)
            }
        }

        guard exists else { return .missingInstalledFile }
        guard let expected = record.installedFingerprint else {
            return .unreadableInstalledFile("The app has no baseline fingerprint for this enabled job.")
        }

        do {
            let actual = try fingerprint(at: url)
            guard actual == expected else {
                return .externallyModified(expected: expected, actual: actual)
            }
        } catch {
            return .unreadableInstalledFile(error.localizedDescription)
        }

        return reconcileExecutionConfiguration(record)
    }

    public func reconcileExecutionConfiguration(_ record: ManagedJobRecord) -> JobReconciliation {
        guard record.enabled else { return .inSync }
        let configurationURL = paths.configurationURL(for: record.id)
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return .missingExecutionConfiguration
        }
        guard let expectedConfiguration = record.installedConfigurationFingerprint else {
            return .unreadableExecutionConfiguration("The app has no baseline fingerprint for this enabled configuration.")
        }
        do {
            let actualConfiguration = try configurationFingerprint(id: record.id)
            return actualConfiguration == expectedConfiguration
                ? .inSync
                : .externallyModifiedConfiguration(expected: expectedConfiguration, actual: actualConfiguration)
        } catch {
            return .unreadableExecutionConfiguration(error.localizedDescription)
        }
    }

    public func fingerprint(at url: URL) throws -> String {
        if AtomicFile.isSymbolicLink(at: url) {
            throw JobRepositoryError.unexpectedSymbolicLink(url)
        }
        return try PropertyListValue.decode(Data(contentsOf: url)).fingerprint
    }

    public func configurationFingerprint(id: UUID) throws -> String {
        let url = paths.configurationURL(for: id)
        if AtomicFile.isSymbolicLink(at: url) {
            throw JobRepositoryError.unexpectedSymbolicLink(url)
        }
        let configuration = try JSONCoding.decoder().decode(
            RunnerConfiguration.self,
            from: Data(contentsOf: url)
        )
        let canonical = try JSONCoding.encoder(pretty: false).encode(configuration)
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    public func removeOwnedFiles(id: UUID, includeLogs: Bool) throws {
        try AtomicFile.removeIfPresent(at: paths.configurationURL(for: id))
        try AtomicFile.removeIfPresent(at: paths.statusURL(for: id))
        if includeLogs {
            try AtomicFile.removeIfPresent(at: paths.logDirectory(for: id))
        }
    }

    private func persist(_ records: [ManagedJobRecord]) throws {
        let data = try JSONCoding.encoder().encode(records)
        try AtomicFile.write(data, to: paths.recordsURL, permissions: 0o600)
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
