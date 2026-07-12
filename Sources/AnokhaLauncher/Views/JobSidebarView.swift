import AnokhaCore
import SwiftUI

struct JobSidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(model.filteredSnapshots, selection: $model.selectedJobID) { snapshot in
            JobSidebarRow(snapshot: snapshot)
                .tag(snapshot.id)
                .contextMenu {
                    Button(snapshot.displayState == .running ? "Restart" : "Run Now") {
                        model.runNow(snapshot.id, restart: snapshot.displayState == .running)
                    }
                    .disabled(!snapshot.canRun)
                    Button(snapshot.record.enabled ? "Disable" : "Enable") {
                        snapshot.record.enabled ? model.disable(snapshot.id) : model.enable(snapshot.id)
                    }
                    .disabled(!snapshot.canToggleEnabled)
                    Button("Duplicate") { model.duplicate(snapshot.id) }
                    Divider()
                    Button("Delete", role: .destructive) { model.requestDelete(snapshot) }
                        .disabled(!snapshot.canDelete)
                }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search jobs")
        .overlay {
            if model.snapshots.isEmpty && !model.isLoading {
                ContentUnavailableView("No Jobs", systemImage: "gearshape.2", description: Text("Create a job to get started."))
            }
        }
        .navigationTitle("Jobs")
        .accessibilityIdentifier("job-sidebar")
    }
}

private struct JobSidebarRow: View {
    let snapshot: JobSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusStyle)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.record.definition.name)
                    .lineLimit(1)
                Text("\(snapshot.displayState.title) · \(snapshot.record.definition.policySummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if snapshot.reconciliation.isConflict || snapshot.displayState == .failed || snapshot.displayState == .needsApproval {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Needs attention")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.record.definition.name), \(snapshot.displayState.title), \(snapshot.record.definition.policySummary)")
    }

    private var statusSymbol: String {
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

    private var statusStyle: AnyShapeStyle {
        switch snapshot.displayState {
        case .running: return AnyShapeStyle(.green)
        case .failed, .conflict: return AnyShapeStyle(.red)
        case .needsApproval, .restarting: return AnyShapeStyle(.orange)
        default: return AnyShapeStyle(.secondary)
        }
    }
}
