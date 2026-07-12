import AppKit
import Foundation

enum FilePanels {
    @MainActor
    static func chooseExecutable() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an Executable or Script"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @MainActor
    static func chooseDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Working Directory"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
