import AnokhaCore
import Foundation
import SwiftUI

struct ConflictResolutionView: View {
    let snapshot: JobSnapshot
    let inspect: () -> Void
    let adopt: () -> Void
    let restore: () -> Void
    let stop: () -> Void
    let stopManaging: () -> Void

    var body: some View {
        GroupBox("External configuration change") {
            VStack(alignment: .leading, spacing: 12) {
                Text(snapshot.reconciliation.summary)
                    .foregroundStyle(.secondary)
                Text("The app will not overwrite it until you choose what happens next.")
                    .font(.callout)
                HStack {
                    Button("Inspect", action: inspect)
                    if snapshot.reconciliation.supportsPlistAdoption {
                        Button("Adopt as Current", action: adopt)
                            .help("Import supported trigger changes, update the runner plan, and reload this app-owned service.")
                    }
                    Button("Restore App Version", action: restore)
                    Spacer()
                    Menu("Safety") {
                        Button("Stop Safely", action: stop)
                        Divider()
                        Button("Stop Managing", role: .destructive, action: stopManaging)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

struct ConflictInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let snapshot: JobSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Inspect Configuration Conflict")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text(snapshot.reconciliation.summary)
                .foregroundStyle(.secondary)

            HSplitView {
                VStack(alignment: .leading) {
                    Text("App version").font(.headline)
                    SelectableCodeBlock(text: appVersionText)
                }
                VStack(alignment: .leading) {
                    Text("Installed file").font(.headline)
                    SelectableCodeBlock(text: installedText)
                }
            }
        }
        .padding(20)
    }

    private var installedText: String {
        let url = snapshot.reconciliation.concernsExecutionConfiguration
            ? model.service.paths.configurationURL(for: snapshot.id)
            : model.service.paths.launchAgentURL(for: snapshot.record.definition)
        guard let data = try? Data(contentsOf: url) else { return "The installed file is missing or unreadable." }
        return String(decoding: data, as: UTF8.self)
    }

    private var appVersionText: String {
        snapshot.reconciliation.concernsExecutionConfiguration
            ? model.generatedExecutionConfiguration(for: snapshot.id)
            : model.generatedPlist(for: snapshot.id)
    }
}
