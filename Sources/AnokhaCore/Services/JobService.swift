import Foundation

public enum JobDisplayState: String, Codable, Sendable {
    case disabled
    case running
    case stopped
    case waiting
    case restarting
    case failed
    case needsApproval
    case conflict
    case unavailable

    public var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .waiting: return "Waiting for schedule"
        case .restarting: return "Waiting to restart"
        case .failed: return "Failed"
        case .needsApproval: return "Approval required"
        case .conflict: return "Changed outside app"
        case .unavailable: return "Unavailable"
        }
    }
}

public struct JobSnapshot: Identifiable, Sendable {
    public var record: ManagedJobRecord
    public var reconciliation: JobReconciliation
    public var launchd: LaunchdSnapshot?
    public var runner: RunnerStatus?
    public var approval: BackgroundApprovalStatus
    public var diagnostic: JobDiagnostic?

    public var id: UUID { record.id }

    public init(
        record: ManagedJobRecord,
        reconciliation: JobReconciliation,
        launchd: LaunchdSnapshot? = nil,
        runner: RunnerStatus? = nil,
        approval: BackgroundApprovalStatus,
        diagnostic: JobDiagnostic? = nil
    ) {
        self.record = record
        self.reconciliation = reconciliation
        self.launchd = launchd
        self.runner = runner
        self.approval = approval
        self.diagnostic = diagnostic
    }

    public var displayState: JobDisplayState {
        if reconciliation.isConflict { return .conflict }
        if !record.enabled { return .disabled }
        if approval == .requiresApproval { return .needsApproval }

        guard let launchd else { return .unavailable }
        switch launchd.loadState {
        case .notLoaded:
            // Runtime status is persisted and may describe the previous process.
            // A booted-out service is stopped regardless of that stale snapshot.
            return .stopped
        case .loaded(let state):
            if let runner {
                let runnerIsCurrent = launchd.processID == runner.runnerPID
                switch runner.state {
                case .running where runnerIsCurrent:
                    return .running
                case .starting where runnerIsCurrent:
                    return .running
                case .waitingToRestart where runnerIsCurrent:
                    return .restarting
                case .failedToLaunch:
                    return .failed
                case .exited:
                    if let code = runner.lastExitCode, code != 0 { return .failed }
                default:
                    break
                }
            }
            if let exitCode = launchd.lastExitCode, exitCode != 0 { return .failed }
            if state?.lowercased() == "running" || launchd.processID != nil { return .running }
            switch record.definition.activation {
            case .scheduled, .manual: return .waiting
            case .atLogin, .keepRunning: return .stopped
            }
        }
    }

    public var canRun: Bool {
        record.enabled && !reconciliation.isConflict && approval != .requiresApproval
    }

    public var canStop: Bool {
        guard record.enabled else { return false }
        if reconciliation.isConflict { return true }
        return displayState == .running || displayState == .restarting
    }

    public var canEdit: Bool { !reconciliation.isConflict }
    public var canToggleEnabled: Bool { !reconciliation.isConflict }
    public var canDelete: Bool { !reconciliation.isConflict }
}

public enum JobServiceError: LocalizedError {
    case bundledRunnerMissing(URL)
    case cannotMutateConflict(JobReconciliation)
    case rollbackFailed(operation: String, recovery: String)

    public var errorDescription: String? {
        switch self {
        case .bundledRunnerMissing(let url):
            return "The bundled job runner is missing at \(url.path)."
        case .cannotMutateConflict(let conflict):
            return "Resolve the external configuration change before saving: \(conflict.summary)"
        case .rollbackFailed(let operation, let recovery):
            return "The update failed (\(operation)), and the previous LaunchAgent could not be reloaded (\(recovery)). Its files were restored, but the job is stopped."
        }
    }
}

public final class JobService: @unchecked Sendable {
    public let paths: AppPaths
    public let repository: JobRepository
    public let launchd: LaunchdClient
    public let logService: LogService
    public let diagnostics: DiagnosticsService
    public let approvalService: BackgroundApprovalService

    private let helperInstaller: HelperInstaller
    private let executionCompiler = ExecutionPlanCompiler()
    private let launchAgentCompiler = LaunchAgentCompiler()
    private let launchAgentImporter = LaunchAgentImporter()

    public init(
        paths: AppPaths = .live,
        bundledRunnerURL: URL,
        launchd: LaunchdClient = LaunchdClient()
    ) {
        self.paths = paths
        self.repository = JobRepository(paths: paths)
        self.launchd = launchd
        self.logService = LogService(paths: paths)
        self.diagnostics = DiagnosticsService()
        self.approvalService = BackgroundApprovalService()
        self.helperInstaller = HelperInstaller(
            bundledExecutableURL: bundledRunnerURL,
            installedExecutableURL: paths.runnerExecutableURL
        )
    }

    public func loadSnapshots() throws -> [JobSnapshot] {
        try repository.prepareDirectories()
        return try repository.loadRecords().map(snapshot)
    }

    public func save(
        definition: JobDefinition,
        enabled: Bool,
        expectedRevision: Int? = nil,
        allowConflictOverwrite: Bool = false
    ) throws -> ManagedJobRecord {
        try repository.prepareDirectories()
        let report = definition.validate()
        // Disabled records are drafts and may be incomplete. Installation never is.
        if enabled, !report.isValid {
            throw JobConfigurationError.validationFailed(report)
        }

        let existing = try repository.loadRecords().first { $0.id == definition.id }
        if let existing, let expectedRevision, existing.revision != expectedRevision {
            throw JobRepositoryError.revisionConflict(expected: expectedRevision, actual: existing.revision)
        }

        if let existing {
            let reconciliation = repository.reconcile(existing)
            if reconciliation.isConflict && !allowConflictOverwrite {
                throw JobServiceError.cannotMutateConflict(reconciliation)
            }
        }

        if enabled {
            try installEnabled(definition: definition, replacing: existing)
        } else if let existing, existing.enabled {
            try disableArtifacts(for: existing)
        }

        let now = Date()
        let record = ManagedJobRecord(
            definition: definition,
            enabled: enabled,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            revision: (existing?.revision ?? 0) + 1,
            installedFingerprint: enabled ? try repository.fingerprint(at: paths.launchAgentURL(for: definition)) : nil,
            installedConfigurationFingerprint: enabled ? try repository.configurationFingerprint(id: definition.id) : nil
        )
        try repository.upsert(record, expectedRevision: existing?.revision)
        return record
    }

    public func enable(id: UUID) throws -> ManagedJobRecord {
        let record = try repository.record(id: id)
        return try save(definition: record.definition, enabled: true, expectedRevision: record.revision)
    }

    public func disable(id: UUID) throws -> ManagedJobRecord {
        let record = try repository.record(id: id)
        let reconciliation = repository.reconcile(record)
        guard reconciliation == .inSync else { throw JobServiceError.cannotMutateConflict(reconciliation) }
        if record.enabled { try disableArtifacts(for: record) }

        var updated = record
        updated.enabled = false
        updated.installedFingerprint = nil
        updated.installedConfigurationFingerprint = nil
        updated.updatedAt = Date()
        updated.revision += 1
        try repository.upsert(updated, expectedRevision: record.revision)
        return updated
    }

    public func runNow(id: UUID, restartIfRunning: Bool = false) throws {
        let record = try repository.record(id: id)
        guard record.enabled else {
            throw NSError(domain: "AnokhaLauncher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enable this job before running it."])
        }
        let reconciliation = repository.reconcile(record)
        guard reconciliation == .inSync else { throw JobServiceError.cannotMutateConflict(reconciliation) }
        let state = try launchd.query(label: record.definition.label)
        if state.loadState == .notLoaded {
            try launchd.bootstrap(plistURL: paths.launchAgentURL(for: record.definition))
        }
        try launchd.kickstart(label: record.definition.label, restartIfRunning: restartIfRunning)
    }

    /// Stops the active command without removing its enabled intent. Ordinary
    /// jobs remain loaded for later schedules; keep-running or conflicted jobs
    /// must be booted out for the rest of this login session.
    public func stop(id: UUID) throws {
        let record = try repository.record(id: id)
        let reconciliation = repository.reconcile(record)
        if reconciliation.isConflict || record.definition.activation.kind == .keepRunning {
            try launchd.bootout(label: record.definition.label)
        } else {
            try launchd.terminate(label: record.definition.label)
        }
    }

    public func duplicate(id: UUID) throws -> ManagedJobRecord {
        let source = try repository.record(id: id)
        var definition = source.definition
        definition.id = UUID()
        definition.name += " Copy"
        return try save(definition: definition, enabled: false)
    }

    public func delete(id: UUID) throws {
        let record = try repository.record(id: id)
        let reconciliation = repository.reconcile(record)
        guard reconciliation == .inSync else { throw JobServiceError.cannotMutateConflict(reconciliation) }
        if record.enabled { try disableArtifacts(for: record) }
        try repository.removeOwnedFiles(id: id, includeLogs: true)
        try repository.removeRecord(id: id)
    }

    public func restoreManagedVersion(id: UUID) throws -> ManagedJobRecord {
        let record = try repository.record(id: id)
        if !record.enabled {
            let plistURL = paths.launchAgentURL(for: record.definition)
            let externalData = try? Data(contentsOf: plistURL)
            try AtomicFile.removeIfPresent(at: plistURL)
            do {
                try launchd.bootout(label: record.definition.label)
            } catch {
                restore(externalData, to: plistURL, permissions: 0o600)
                throw error
            }

            var restored = record
            restored.installedFingerprint = nil
            restored.installedConfigurationFingerprint = nil
            restored.updatedAt = Date()
            restored.revision += 1
            try repository.upsert(restored, expectedRevision: record.revision)
            return restored
        }
        return try save(
            definition: record.definition,
            enabled: record.enabled,
            expectedRevision: record.revision,
            allowConflictOverwrite: true
        )
    }

    /// Losslessly adopts supported trigger edits, updates the runner plan, and
    /// reloads the exact app-owned service. Arbitrary plist keys are rejected.
    public func adoptCurrentInstalledFile(id: UUID) throws -> ManagedJobRecord {
        let original = try repository.record(id: id)
        var record = original
        let configurationReconciliation = repository.reconcileExecutionConfiguration(original)
        guard configurationReconciliation == .inSync else {
            throw JobServiceError.cannotMutateConflict(configurationReconciliation)
        }
        let url = paths.launchAgentURL(for: record.definition)
        _ = try repository.fingerprint(at: url) // also rejects unexpected symlinks
        let externalData = try Data(contentsOf: url)
        let adoptedDefinition = try launchAgentImporter.importSupportedChanges(
            from: externalData,
            current: record.definition,
            runnerExecutableURL: paths.runnerExecutableURL,
            configurationURL: paths.configurationURL(for: id)
        )
        let oldConfiguration = try? Data(contentsOf: paths.configurationURL(for: id))
        let adoptedConfiguration = try executionCompiler.compile(adoptedDefinition, paths: paths)

        try launchd.bootout(label: original.definition.label)
        do {
            try repository.write(configuration: adoptedConfiguration)
            do {
                try launchd.bootstrap(plistURL: url)
            } catch {
                guard approvalService.status(forLegacyPlistAt: url) == .requiresApproval else { throw error }
            }
        } catch {
            restore(oldConfiguration, to: paths.configurationURL(for: id), permissions: 0o600)
            _ = try? launchd.bootstrap(plistURL: url)
            throw error
        }

        record.definition = adoptedDefinition
        record.installedFingerprint = try repository.fingerprint(at: url)
        record.installedConfigurationFingerprint = try repository.configurationFingerprint(id: id)
        record.enabled = true
        record.updatedAt = Date()
        record.revision += 1
        try repository.upsert(record, expectedRevision: record.revision - 1)
        return record
    }

    /// Removes only the app record. The external plist and its supporting files stay intact.
    public func stopManaging(id: UUID) throws {
        try repository.removeRecord(id: id)
    }

    public func generatedPlistText(id: UUID) throws -> String {
        let record = try repository.record(id: id)
        let document = try launchAgentCompiler.compile(
            record.definition,
            runnerExecutableURL: paths.runnerExecutableURL,
            configurationURL: paths.configurationURL(for: id)
        )
        return String(decoding: document.data, as: UTF8.self)
    }

    public func generatedConfigurationText(id: UUID) throws -> String {
        let record = try repository.record(id: id)
        let configuration = try executionCompiler.compile(record.definition, paths: paths)
        return String(decoding: try JSONCoding.encoder().encode(configuration), as: UTF8.self)
    }

    private func snapshot(_ record: ManagedJobRecord) -> JobSnapshot {
        let reconciliation = repository.reconcile(record)
        let launchdSnapshot: LaunchdSnapshot?
        if record.enabled {
            launchdSnapshot = try? launchd.query(label: record.definition.label)
        } else {
            launchdSnapshot = nil
        }
        let runner = repository.readRunnerStatus(id: record.id)
        let approval: BackgroundApprovalStatus = record.enabled
            ? approvalService.status(forLegacyPlistAt: paths.launchAgentURL(for: record.definition))
            : .notRegistered
        let diagnostic: JobDiagnostic?
        if reconciliation.isConflict {
            diagnostic = .init(category: .externalChange, title: "Configuration changed outside the app", message: reconciliation.summary)
        } else if approval == .requiresApproval {
            diagnostic = .init(category: .backgroundApprovalRequired, title: "Background approval required", message: "Allow Anokha Launcher in System Settings > General > Login Items.")
        } else if let runner {
            diagnostic = diagnostics.diagnostic(for: runner)
        } else if let exitCode = launchdSnapshot?.lastExitCode, exitCode != 0 {
            diagnostic = .init(
                category: .launchFailed,
                title: "Runner exited with status \(exitCode)",
                message: "Open the error log and advanced launchctl details to diagnose the startup failure.",
                rawDetails: launchdSnapshot?.rawOutput
            )
        } else {
            diagnostic = nil
        }
        return JobSnapshot(
            record: record,
            reconciliation: reconciliation,
            launchd: launchdSnapshot,
            runner: runner,
            approval: approval,
            diagnostic: diagnostic
        )
    }

    private func installEnabled(definition: JobDefinition, replacing existing: ManagedJobRecord?) throws {
        guard FileManager.default.fileExists(atPath: helperInstaller.bundledExecutableURL.path) else {
            throw JobServiceError.bundledRunnerMissing(helperInstaller.bundledExecutableURL)
        }
        try helperInstaller.installIfNeeded()

        let configuration = try executionCompiler.compile(definition, paths: paths)
        let document = try launchAgentCompiler.compile(
            definition,
            runnerExecutableURL: paths.runnerExecutableURL,
            configurationURL: paths.configurationURL(for: definition.id)
        )
        let plistURL = paths.launchAgentURL(for: definition)
        let configURL = paths.configurationURL(for: definition.id)
        let oldPlist = try? Data(contentsOf: plistURL)
        let oldConfig = try? Data(contentsOf: configURL)

        if existing?.enabled == true {
            try launchd.bootout(label: definition.label)
        }

        do {
            try repository.write(configuration: configuration)
            try AtomicFile.write(document.data, to: plistURL, permissions: 0o600)
            try launchd.bootstrap(plistURL: plistURL)
        } catch let operationError {
            if approvalService.status(forLegacyPlistAt: plistURL) == .requiresApproval {
                // Keep the validated persistent plist so System Settings can
                // approve it. The snapshot exposes this as a distinct state.
                return
            }
            _ = try? launchd.bootout(label: definition.label)
            restore(oldPlist, to: plistURL, permissions: 0o600)
            restore(oldConfig, to: configURL, permissions: 0o600)
            if oldPlist != nil, existing?.enabled == true {
                do {
                    try launchd.bootstrap(plistURL: plistURL)
                } catch let recoveryError {
                    throw JobServiceError.rollbackFailed(
                        operation: operationError.localizedDescription,
                        recovery: recoveryError.localizedDescription
                    )
                }
            }
            throw operationError
        }
    }

    private func disableArtifacts(for record: ManagedJobRecord) throws {
        let plistURL = paths.launchAgentURL(for: record.definition)
        let oldPlist = try? Data(contentsOf: plistURL)
        // Remove persistence first. A crash between these steps cannot resurrect the job at next login.
        try AtomicFile.removeIfPresent(at: plistURL)
        do {
            try launchd.bootout(label: record.definition.label)
        } catch {
            restore(oldPlist, to: plistURL, permissions: 0o600)
            throw error
        }
    }

    private func restore(_ data: Data?, to url: URL, permissions: Int) {
        if let data {
            try? AtomicFile.write(data, to: url, permissions: permissions)
        } else {
            try? AtomicFile.removeIfPresent(at: url)
        }
    }
}
