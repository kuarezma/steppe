import Foundation

/// Small append-only file logger with size-based rotation. Thread-safe.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let queue = DispatchQueue(label: "steppe.log")
    private var fileURL: URL?
    private let maxBytes = 2 * 1024 * 1024
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init() {}

    /// Never blocks the caller: the first access to a removable volume can wait on a macOS permission prompt.
    public func configure(fileURL: URL) {
        queue.async {
            self.fileURL = fileURL
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    public func info(_ message: @autoclosure () -> String) { write("INFO", message()) }
    public func warn(_ message: @autoclosure () -> String) { write("WARN", message()) }
    public func error(_ message: @autoclosure () -> String) { write("ERROR", message()) }

    private func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(Redaction.redact(message))\n"
        queue.async { [self] in
            guard let url = fileURL else { return }
            rotateIfNeeded(url)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    /// Last `count` lines of the log, already redacted.
    public func tail(lines count: Int = 200) -> String {
        queue.sync {
            guard let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).joined(separator: "\n")
        }
    }
}
