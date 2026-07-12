import AnokhaCore
import Foundation
import Observation

struct EditorPresentation: Identifiable {
    let id = UUID()
    var definition: JobDefinition
    var expectedRevision: Int?
    var initiallyEnabled: Bool
}

struct LogsPresentation: Identifiable {
    let id = UUID()
    var jobID: UUID
}

struct DeletePresentation: Identifiable {
    var id: UUID { jobID }
    var jobID: UUID
    var name: String
}

struct AppErrorPresentation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var rawDetails: String?
}

struct StopManagingPresentation: Identifiable {
    var id: UUID { jobID }
    var jobID: UUID
    var name: String
}

@MainActor
@Observable
final class AppModel {
    private(set) var snapshots: [JobSnapshot] = []
    var selectedJobID: UUID?
    var searchText = ""
    var editor: EditorPresentation?
    var logs: LogsPresentation?
    var pendingDelete: DeletePresentation?
    var pendingStopManaging: StopManagingPresentation?
    var errorPresentation: AppErrorPresentation?
    private(set) var busyJobIDs: Set<UUID> = []
    private(set) var isLoading = false
    private var refreshGeneration = 0

    let service: JobService

    init(service: JobService? = nil) {
        if let service {
            self.service = service
        } else {
            let bundledRunner = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/AnokhaJobRunner")
            self.service = JobService(bundledRunnerURL: bundledRunner)
        }
    }

    var filteredSnapshots: [JobSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return snapshots }
        return snapshots.filter { snapshot in
            let job = snapshot.record.definition
            return job.name.lowercased().contains(query)
                || job.executionSummary.lowercased().contains(query)
                || job.policySummary.lowercased().contains(query)
        }
    }

    var selectedSnapshot: JobSnapshot? {
        snapshots.first { $0.id == selectedJobID }
    }

    func refresh(showErrors: Bool = false) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        do {
            let service = self.service
            let loaded = try await Task.detached(priority: .utility) {
                try service.loadSnapshots()
            }.value
            guard generation == refreshGeneration else { return }
            snapshots = loaded
            if let selectedJobID, !snapshots.contains(where: { $0.id == selectedJobID }) {
                self.selectedJobID = snapshots.first?.id
            } else if selectedJobID == nil {
                selectedJobID = snapshots.first?.id
            }
        } catch {
            if showErrors { present(error) }
        }
        if generation == refreshGeneration { isLoading = false }
    }

    func poll() async {
        await refresh(showErrors: true)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { break }
            await refresh()
        }
    }

    func createJob() {
        editor = EditorPresentation(
            definition: .newDraft(),
            expectedRevision: nil,
            initiallyEnabled: false
        )
    }

    func editSelectedJob() {
        guard let snapshot = selectedSnapshot, !snapshot.reconciliation.isConflict else { return }
        editor = EditorPresentation(
            definition: snapshot.record.definition,
            expectedRevision: snapshot.record.revision,
            initiallyEnabled: snapshot.record.enabled
        )
    }

    func save(_ definition: JobDefinition, enabled: Bool, expectedRevision: Int?) {
        guard !busyJobIDs.contains(definition.id) else { return }
        busyJobIDs.insert(definition.id)
        let service = self.service
        Task {
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    try service.save(
                        definition: definition,
                        enabled: enabled,
                        expectedRevision: expectedRevision
                    )
                }.value
                editor = nil
                selectedJobID = record.id
            } catch {
                present(error)
            }
            busyJobIDs.remove(definition.id)
            await refresh()
        }
    }

    func enable(_ id: UUID) { perform(id) { service in _ = try service.enable(id: id); return nil } }
    func disable(_ id: UUID) { perform(id) { service in _ = try service.disable(id: id); return nil } }
    func runNow(_ id: UUID, restart: Bool = false) { perform(id) { service in try service.runNow(id: id, restartIfRunning: restart); return nil } }
    func stop(_ id: UUID) { perform(id) { service in try service.stop(id: id); return nil } }

    func duplicate(_ id: UUID) {
        perform(id) { service in try service.duplicate(id: id).id }
    }

    func requestDelete(_ snapshot: JobSnapshot) {
        pendingDelete = DeletePresentation(jobID: snapshot.id, name: snapshot.record.definition.name)
    }

    func confirmDelete() {
        guard let pendingDelete else { return }
        self.pendingDelete = nil
        perform(pendingDelete.jobID) { service in
            try service.delete(id: pendingDelete.jobID)
            return pendingDelete.jobID
        } onSuccess: { [weak self] deletedID in
            if self?.selectedJobID == deletedID { self?.selectedJobID = nil }
        }
    }

    func showLogs(_ id: UUID) {
        logs = LogsPresentation(jobID: id)
    }

    func restore(_ id: UUID) { perform(id) { service in _ = try service.restoreManagedVersion(id: id); return nil } }
    func adopt(_ id: UUID) { perform(id) { service in _ = try service.adoptCurrentInstalledFile(id: id); return nil } }

    func requestStopManaging(_ snapshot: JobSnapshot) {
        pendingStopManaging = StopManagingPresentation(jobID: snapshot.id, name: snapshot.record.definition.name)
    }

    func confirmStopManaging() {
        guard let pending = pendingStopManaging else { return }
        pendingStopManaging = nil
        perform(pending.jobID) { service in
            try service.stopManaging(id: pending.jobID)
            return pending.jobID
        } onSuccess: { [weak self] removedID in
            if self?.selectedJobID == removedID { self?.selectedJobID = nil }
        }
    }

    func openLoginItemsSettings() {
        service.approvalService.openLoginItemsSettings()
    }

    func generatedPlist(for id: UUID) -> String {
        (try? service.generatedPlistText(id: id)) ?? "Generated configuration is unavailable."
    }

    func generatedExecutionConfiguration(for id: UUID) -> String {
        (try? service.generatedConfigurationText(id: id)) ?? "Generated execution configuration is unavailable."
    }

    private func perform(
        _ id: UUID,
        operation: @escaping @Sendable (JobService) throws -> UUID?,
        onSuccess: ((UUID?) -> Void)? = nil
    ) {
        guard !busyJobIDs.contains(id) else { return }
        busyJobIDs.insert(id)
        let service = self.service
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try operation(service)
                }.value
                if let onSuccess {
                    onSuccess(result)
                } else if let selectedID = result {
                    selectedJobID = selectedID
                }
            } catch {
                present(error)
            }
            busyJobIDs.remove(id)
            await refresh()
        }
    }

    private func present(_ error: Error) {
        let diagnostic = service.diagnostics.diagnostic(for: error)
        errorPresentation = AppErrorPresentation(
            title: diagnostic.title,
            message: diagnostic.message,
            rawDetails: diagnostic.rawDetails
        )
    }
}
