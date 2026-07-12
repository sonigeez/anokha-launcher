import AnokhaCore
import AppKit
import SwiftUI

struct JobDetailView: View {
    @Bindable var model: AppModel
    let snapshot: JobSnapshot
    @State private var showAdvanced = false
    @State private var showConflictInspector = false

    private var job: JobDefinition { snapshot.record.definition }
    private var isBusy: Bool { model.busyJobIDs.contains(snapshot.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let diagnostic = snapshot.diagnostic {
                    DiagnosticBanner(diagnostic: diagnostic) {
                        if diagnostic.category == .backgroundApprovalRequired {
                            model.openLoginItemsSettings()
                        }
                    }
                }

                if snapshot.reconciliation.isConflict {
                    ConflictResolutionView(
                        snapshot: snapshot,
                        inspect: { showConflictInspector = true },
                        adopt: { model.adopt(snapshot.id) },
                        restore: { model.restore(snapshot.id) },
                        stop: { model.stop(snapshot.id) },
                        stopManaging: { model.requestStopManaging(snapshot) }
                    )
                }

                overview
                execution

                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Generated LaunchAgent")
                            .font(.headline)
                        SelectableCodeBlock(text: model.generatedPlist(for: snapshot.id))

                        Text("Raw launchctl output")
                            .font(.headline)
                        SelectableCodeBlock(text: snapshot.launchd?.rawOutput.isEmpty == false
                            ? snapshot.launchd!.rawOutput
                            : "No raw launchctl output is available.")
                    }
                    .padding(.top, 8)
                }
            }
            .padding(22)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle(job.name)
        .toolbar { toolbar }
        .sheet(isPresented: $showConflictInspector) {
            ConflictInspectorView(model: model, snapshot: snapshot)
                .frame(minWidth: 820, minHeight: 600)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.name)
                    .font(.largeTitle.bold())
                    .textSelection(.enabled)
                Spacer()
                Label(snapshot.displayState.title, systemImage: stateSymbol)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }
            Text(job.policySummary)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var overview: some View {
        GroupBox("Status") {
            VStack(spacing: 10) {
                LabeledContent("Enabled", value: snapshot.record.enabled ? "Yes" : "No")
                LabeledContent("Current state", value: snapshot.displayState.title)
                LabeledContent("Last run", value: snapshot.runner?.lastStartedAt?.formatted(date: .abbreviated, time: .standard) ?? "Not known")
                LabeledContent("Last exit", value: lastExitSummary)
                LabeledContent("Next expected run", value: nextRunSummary)
            }
            .padding(.top, 4)
        }
    }

    private var execution: some View {
        GroupBox("Execution") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Mode", value: job.command.kind.title)
                LabeledContent("Working directory", value: job.workingDirectory ?? "Home folder (default)")
                LabeledContent("Environment", value: job.environment.isEmpty ? "Default PATH only" : "\(job.environment.count) custom value(s)")
                Divider()
                Text("Exact execution")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(job.executionSummary)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 4)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.runNow(snapshot.id, restart: snapshot.displayState == .running)
            } label: {
                Label(snapshot.displayState == .running ? "Restart" : "Run Now", systemImage: snapshot.displayState == .running ? "arrow.clockwise" : "play.fill")
            }
            .disabled(!snapshot.canRun || isBusy)
            .accessibilityIdentifier("run-now")

            Button {
                model.stop(snapshot.id)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!snapshot.canStop || isBusy)
            .help(job.activation.kind == .keepRunning
                ? "Stop this keep-running job until the next login."
                : "Stop the active command while keeping future schedule triggers loaded.")
            .accessibilityIdentifier("stop-job")

            Button {
                snapshot.record.enabled ? model.disable(snapshot.id) : model.enable(snapshot.id)
            } label: {
                Label(snapshot.record.enabled ? "Disable" : "Enable", systemImage: snapshot.record.enabled ? "pause.fill" : "power")
            }
            .disabled(!snapshot.canToggleEnabled || isBusy)
            .accessibilityIdentifier("toggle-enabled")

            Button {
                model.showLogs(snapshot.id)
            } label: {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
            }
            .accessibilityIdentifier("view-logs")

            Menu {
                Button("Edit") { model.editSelectedJob() }
                    .disabled(!snapshot.canEdit)
                Button("Duplicate") { model.duplicate(snapshot.id) }
                Divider()
                Button("Delete", role: .destructive) { model.requestDelete(snapshot) }
                    .disabled(!snapshot.canDelete)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var lastExitSummary: String {
        guard let runner = snapshot.runner else { return "Not known" }
        if let signal = runner.lastTerminationSignal { return "Signal \(signal)" }
        if let code = runner.lastExitCode { return code == 0 ? "Success (0)" : "Failed (\(code))" }
        return "Not known"
    }

    private var nextRunSummary: String {
        if !snapshot.record.enabled { return "Disabled" }
        guard case .scheduled(let schedule) = job.activation else {
            return job.activation == .manual ? "Manual only" : "Not scheduled"
        }
        if let next = schedule.nextRun(after: Date()) {
            return next.formatted(date: .abbreviated, time: .shortened)
        }
        return "Calculated by launchd after loading"
    }

    private var stateSymbol: String {
        switch snapshot.displayState {
        case .running: return "play.circle.fill"
        case .waiting: return "clock"
        case .restarting: return "arrow.clockwise.circle"
        case .failed: return "xmark.octagon.fill"
        case .needsApproval, .conflict: return "exclamationmark.triangle.fill"
        case .disabled: return "pause.circle"
        case .stopped: return "stop.circle"
        case .unavailable: return "questionmark.circle"
        }
    }
}

private struct DiagnosticBanner: View {
    let diagnostic: JobDiagnostic
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(diagnostic.title).font(.headline)
                Text(diagnostic.message).foregroundStyle(.secondary)
            }
            Spacer()
            if diagnostic.category == .backgroundApprovalRequired {
                Button("Open Settings", action: action)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

struct SelectableCodeBlock: View {
    let text: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .padding(.trailing, 28)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .padding(8)
            .help("Copy")
            .accessibilityLabel("Copy diagnostic text")
        }
        .frame(minHeight: 120, maxHeight: 260)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}
