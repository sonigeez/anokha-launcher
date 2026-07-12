import Foundation

public enum JobLogStream: String, CaseIterable, Identifiable, Sendable {
    case standardOutput
    case standardError

    public var id: String { rawValue }
    public var title: String { self == .standardOutput ? "Output" : "Errors" }
}

public struct JobLogContent: Equatable, Sendable {
    public var text: String
    public var modifiedAt: Date?
    public var byteCount: Int

    public init(text: String, modifiedAt: Date?, byteCount: Int) {
        self.text = text
        self.modifiedAt = modifiedAt
        self.byteCount = byteCount
    }
}

public struct LogService: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func read(
        job: JobDefinition,
        stream: JobLogStream,
        includeBackups: Bool = true,
        maxBytes: Int? = nil
    ) -> JobLogContent {
        let current = url(for: job.id, stream: stream)
        let backupCount = includeBackups ? job.logPolicy.retainedBackups : 0
        var urls: [URL] = backupCount > 0
            ? (1...backupCount).reversed().map { URL(fileURLWithPath: current.path + ".\($0)") }
            : []
        urls.append(current)

        let fileInfo = urls.compactMap { url -> (URL, Int, Date?)? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue else {
                return nil
            }
            return (url, size, attributes[.modificationDate] as? Date)
        }
        let totalBytes = fileInfo.reduce(0) { $0 + $1.1 }
        let data: Data
        if let maxBytes {
            data = readTail(from: fileInfo, maxBytes: max(0, maxBytes))
        } else {
            var full = Data()
            for (url, _, _) in fileInfo {
                if let chunk = try? Data(contentsOf: url) { full.append(chunk) }
            }
            data = full
        }
        return JobLogContent(
            text: String(decoding: data, as: UTF8.self),
            modifiedAt: fileInfo.compactMap(\.2).max(),
            byteCount: totalBytes
        )
    }

    public func clear(job: JobDefinition, stream: JobLogStream? = nil) throws {
        let streams = stream.map { [$0] } ?? JobLogStream.allCases
        for stream in streams {
            let current = url(for: job.id, stream: stream)
            if FileManager.default.fileExists(atPath: current.path) {
                let handle = try FileHandle(forWritingTo: current)
                try handle.truncate(atOffset: 0)
                try handle.close()
            }
            if job.logPolicy.retainedBackups > 0 {
                for index in 1...job.logPolicy.retainedBackups {
                    try AtomicFile.removeIfPresent(at: URL(fileURLWithPath: current.path + ".\(index)"))
                }
            }
        }
    }

    public func url(for jobID: UUID, stream: JobLogStream) -> URL {
        switch stream {
        case .standardOutput: return paths.standardOutputURL(for: jobID)
        case .standardError: return paths.standardErrorURL(for: jobID)
        }
    }

    private func readTail(from files: [(URL, Int, Date?)], maxBytes: Int) -> Data {
        guard maxBytes > 0 else { return Data() }
        var remaining = maxBytes
        var chunks: [Data] = []

        for (url, size, _) in files.reversed() where remaining > 0 {
            do {
                let count = min(size, remaining)
                let handle = try FileHandle(forReadingFrom: url)
                try handle.seek(toOffset: UInt64(max(0, size - count)))
                let chunk = try handle.readToEnd() ?? Data()
                try handle.close()
                chunks.insert(chunk.count > count ? chunk.suffix(count) : chunk, at: 0)
                remaining -= min(count, chunk.count)
            } catch {
                continue
            }
        }

        return chunks.reduce(into: Data()) { $0.append($1) }
    }
}

public final class RollingLogWriter: @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let backupCount: Int
    private let lock = NSLock()

    public init(url: URL, maxBytes: Int, backupCount: Int) throws {
        self.url = url
        self.maxBytes = max(1, maxBytes)
        self.backupCount = max(0, backupCount)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try lock.withLock {
            var payload = data
            if payload.count > maxBytes {
                payload = payload.suffix(maxBytes)
            }

            let currentSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
            if currentSize + payload.count > maxBytes {
                try rotate()
            }

            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            try handle.close()
        }
    }

    private func rotate() throws {
        if backupCount == 0 {
            try AtomicFile.removeIfPresent(at: url)
            return
        }

        try AtomicFile.removeIfPresent(at: backupURL(backupCount))
        if backupCount > 1 {
            for index in stride(from: backupCount - 1, through: 1, by: -1) {
                let source = backupURL(index)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.moveItem(at: source, to: backupURL(index + 1))
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: backupURL(1))
        }
    }

    private func backupURL(_ index: Int) -> URL {
        URL(fileURLWithPath: url.path + ".\(index)")
    }
}

private extension NSLock {
    func withLock<T>(_ work: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try work()
    }
}
