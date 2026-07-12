import Foundation

public struct HelperInstaller: Sendable {
    public let bundledExecutableURL: URL
    public let installedExecutableURL: URL

    public init(bundledExecutableURL: URL, installedExecutableURL: URL) {
        self.bundledExecutableURL = bundledExecutableURL
        self.installedExecutableURL = installedExecutableURL
    }

    public func installIfNeeded() throws {
        let sourceData = try Data(contentsOf: bundledExecutableURL)
        if let installedData = try? Data(contentsOf: installedExecutableURL), installedData == sourceData {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedExecutableURL.path)
            return
        }
        try AtomicFile.write(sourceData, to: installedExecutableURL, permissions: 0o755)
    }
}
