import AnokhaCore
import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            JobSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 360)
        } detail: {
            if let snapshot = model.selectedSnapshot {
                JobDetailView(model: model, snapshot: snapshot)
                    .id(snapshot.id)
            } else {
                ContentUnavailableView {
                    Label("No Job Selected", systemImage: "gearshape.2")
                } description: {
                    Text("Select a job or create one to run work in the background.")
                } actions: {
                    Button("New Job") { model.createJob() }
                        .keyboardShortcut("n", modifiers: .command)
                        .accessibilityIdentifier("empty-new-job")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.createJob()
                } label: {
                    Label("New Job", systemImage: "plus")
                }
                .help("New Job (⌘N)")
                .accessibilityIdentifier("toolbar-new-job")
            }
        }
        .sheet(item: $model.editor) { presentation in
            JobEditorView(
                presentation: presentation,
                onCancel: { model.editor = nil },
                onSave: { definition, enabled in
                    model.save(definition, enabled: enabled, expectedRevision: presentation.expectedRevision)
                }
            )
        }
        .sheet(item: $model.logs) { presentation in
            if let snapshot = model.snapshots.first(where: { $0.id == presentation.jobID }) {
                JobLogsView(snapshot: snapshot, service: model.service)
                    .frame(minWidth: 760, minHeight: 520)
            }
        }
        .alert(
            model.errorPresentation?.title ?? "Operation Failed",
            isPresented: Binding(
                get: { model.errorPresentation != nil },
                set: { if !$0 { model.errorPresentation = nil } }
            ),
            presenting: model.errorPresentation
        ) { error in
            if let rawDetails = error.rawDetails {
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rawDetails, forType: .string)
                }
            }
            Button("OK", role: .cancel) { model.errorPresentation = nil }
        } message: { error in
            if let rawDetails = error.rawDetails {
                Text("\(error.message)\n\n\(String(rawDetails.prefix(1_200)))")
            } else {
                Text(error.message)
            }
        }
        .confirmationDialog(
            "Delete this job?",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { if !$0 { model.pendingDelete = nil } }
            ),
            presenting: model.pendingDelete
        ) { _ in
            Button("Delete Job and Logs", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: { pending in
            Text("“\(pending.name)” will be stopped. Its LaunchAgent, configuration, and app-owned logs will be deleted.")
        }
        .confirmationDialog(
            "Stop managing this job?",
            isPresented: Binding(
                get: { model.pendingStopManaging != nil },
                set: { if !$0 { model.pendingStopManaging = nil } }
            ),
            presenting: model.pendingStopManaging
        ) { _ in
            Button("Stop Managing", role: .destructive) { model.confirmStopManaging() }
            Button("Cancel", role: .cancel) { model.pendingStopManaging = nil }
        } message: { pending in
            Text("“\(pending.name)” will disappear from the app, but its external plist, runner configuration, logs, and any live process will be left untouched.")
        }
    }
}
