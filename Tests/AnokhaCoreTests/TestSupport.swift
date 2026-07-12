import AnokhaCore
import Foundation

struct StubFileSystem: FileSystemChecking {
    var existing: Set<String> = []
    var directories: Set<String> = []
    var regularFiles: Set<String> = []
    var executableFiles: Set<String> = []
    var permissions: [String: Int] = [:]

    func itemExists(at path: String) -> Bool { existing.contains(path) }
    func isDirectory(at path: String) -> Bool { directories.contains(path) }
    func isRegularFile(at path: String) -> Bool { regularFiles.contains(path) }
    func isExecutable(at path: String) -> Bool { executableFiles.contains(path) }
    func posixPermissions(at path: String) -> Int? { permissions[path] }
}

extension JobDefinition {
    static func validShell(
        id: UUID = UUID(),
        activation: JobActivation = .atLogin,
        restartPolicy: RestartPolicy = .never
    ) -> JobDefinition {
        JobDefinition(
            id: id,
            name: "Test Job",
            command: .shell(command: "echo hello"),
            activation: activation,
            restartPolicy: restartPolicy
        )
    }
}

func temporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AnokhaLauncherTests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
