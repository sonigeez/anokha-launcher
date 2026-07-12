import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct AnokhaLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Anokha Launcher", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 520)
                .task { await model.poll() }
        }
        .defaultSize(width: 1_020, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Job") { model.createJob() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Job") {
                Button(model.selectedSnapshot?.displayState == .running ? "Restart" : "Run Now") {
                    if let snapshot = model.selectedSnapshot {
                        model.runNow(snapshot.id, restart: snapshot.displayState == .running)
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selectedSnapshot?.canRun != true)

                Button("Stop") {
                    if let id = model.selectedJobID { model.stop(id) }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.selectedSnapshot?.canStop != true)

                Divider()

                Button("Edit Job") { model.editSelectedJob() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.selectedSnapshot?.canEdit != true)
            }
        }
    }
}
