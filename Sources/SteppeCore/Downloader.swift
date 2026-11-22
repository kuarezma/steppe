import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public let received: Int64
    public let total: Int64
    public var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
}

public enum DownloadError: Error, LocalizedError {
    case badStatus(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return L("The server answered with HTTP %d.", Int32(code))
        case .sizeMismatch: return L("A download is incomplete or damaged. Please try again.")
        case .checksumMismatch: return L("The downloaded file failed its integrity check.")
        case .network(let m): return m
        }
    }
}

/// Resumable HTTPS downloader with SHA-256 verification.
public enum Downloader {
    public static func download(
        url: URL,
        to destination: URL,
        expectedSHA256: String?,
        expectedSize: Int64?,
        maxAttempts: Int = 5,
        configuration: URLSessionConfiguration? = nil,
        retryDelayUnit: UInt64 = 1_000_000_000,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: destination.path) {
            if let expectedSHA256, (try? Hashing.sha256(of: destination)) == expectedSHA256 {
                progress(DownloadProgress(received: expectedSize ?? 1, total: expectedSize ?? 1))
                return
            }
            try? fm.removeItem(at: destination)
        }

        let part = destination.appendingPathExtension("part")
        var attempt = 0
        while true {
            attempt += 1
            do {
                // Without a checksum nothing proves that a partial file and the rest the server sends belong
                // to the same version, so unpinned downloads always start over cleanly (both across runs and retries).
                if expectedSHA256 == nil {
                    if fm.fileExists(atPath: part.path) {
                        try fm.removeItem(at: part)
                    }
                    try? fm.removeItem(at: part.appendingPathExtension("meta"))
                }
                try await fetch(url: url, part: part, expectedSize: expectedSize, configuration: configuration, progress: progress)
                let size = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
                if let expectedSize, size != expectedSize {
                    try? fm.removeItem(at: part)
                    throw DownloadError.sizeMismatch(expected: expectedSize, actual: size)
                }
                if let expectedSHA256 {
                    let actual = try Hashing.sha256(of: part)
                    guard actual == expectedSHA256 else {
                        try? fm.removeItem(at: part)
                        throw DownloadError.checksumMismatch(expected: expectedSHA256, actual: actual)
                    }
                }
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DownloadError {
                // Non-transient answers are not retried (416 is retried once the stale .part file has been removed).
                if case .badStatus(let code) = error, code != 429, code != 416, code < 500 { throw error }
                if attempt >= maxAttempts { throw error }
            } catch {
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                let nsError = error as NSError
                let outOfSpace = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
                    || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(POSIXErrorCode.ENOSPC.rawValue))
                if outOfSpace || attempt >= maxAttempts { throw DownloadError.network(error.localizedDescription) }
            }
            try await Task.sleep(nanoseconds: UInt64(min(30, 1 << attempt)) * retryDelayUnit)
        }

        try? fm.removeItem(at: part.appendingPathExtension("meta"))
        try fm.moveItem(at: part, to: destination)
    }

    private static func fetch(
        url: URL,
        part: URL,
        expectedSize: Int64?,
        configuration: URLSessionConfiguration?,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        let metaURL = part.appendingPathExtension("meta")
        var existing = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        if let expectedSize, existing > expectedSize {
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: metaURL)
            existing = 0
        }
        if let expectedSize, existing == expectedSize { return }

        var request = URLRequest(url: url)
        request.setValue("Steppe", forHTTPHeaderField: "User-Agent")
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
            if let validator = try? String(contentsOf: metaURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !validator.isEmpty {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        }

        let delegate = DownloadDelegate(part: part, metaURL: metaURL, resumeOffset: existing, progress: progress)
        let config = configuration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 60
            c.waitsForConnectivity = true
            return c
        }()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.attach(continuation: continuation, task: task)
            }
        } onCancel: {
            delegate.cancel(task: task)
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let part: URL
    let metaURL: URL
    var resumeOffset: Int64
    let progress: @Sendable (DownloadProgress) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completed = false
    private var cancelled = false
    private var completionError: Error?
    private var handle: FileHandle?
    private var received: Int64
    private var total: Int64 = 0
    private var lastReport = Date.distantPast
    private var failure: Error?

    init(part: URL, metaURL: URL, resumeOffset: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.part = part
        self.metaURL = metaURL
        self.resumeOffset = resumeOffset
        self.received = resumeOffset
        self.progress = progress
    }

    func attach(continuation: CheckedContinuation<Void, Error>, task: URLSessionDataTask) {
        lock.lock()
        if completed {
            let err = completionError ?? CancellationError()
            lock.unlock()
            continuation.resume(throwing: err)
            return
        }
        if cancelled {
            completed = true
            lock.unlock()
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    func cancel(task: URLSessionDataTask) {
        lock.lock()
        cancelled = true
        lock.unlock()
        task.cancel()
    }

    private static func validator(from response: HTTPURLResponse) -> String? {
        if let etag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !etag.isEmpty, !etag.hasPrefix("W/") {
            return etag
        }
        if let modified = response.value(forHTTPHeaderField: "Last-Modified")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modified.isEmpty {
            return modified
        }
        return nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = DownloadError.network(L("The server sent an unexpected response."))
            return completionHandler(.cancel)
        }
        let fm = FileManager.default
        switch http.statusCode {
        case 206:
            total = http.expectedContentLength > 0 ? resumeOffset + http.expectedContentLength : 0
        case 200:
            // Server ignored the range request or If-Range detected a newer remote file: start over.
            resumeOffset = 0
            received = 0
            total = max(0, http.expectedContentLength)
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: metaURL)
        case 416:
            // Our partial file is unusable; discard and let the caller retry from scratch.
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: metaURL)
            failure = DownloadError.badStatus(416)
            return completionHandler(.cancel)
        default:
            failure = DownloadError.badStatus(http.statusCode)
            return completionHandler(.cancel)
        }
        if let validator = Self.validator(from: http) {
            try? validator.write(to: metaURL, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        do {
            handle = try FileHandle(forWritingTo: part)
            _ = try handle?.seekToEnd()
        } catch {
            failure = error
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.1 {
            lastReport = now
            progress(DownloadProgress(received: received, total: total))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let finalError: Error? = failure ?? (cancelled ? CancellationError() : error)
        let cont = continuation
        continuation = nil
        completionError = finalError
        lock.unlock()
        if let cont {
            if let finalError {
                cont.resume(throwing: finalError)
            } else {
                progress(DownloadProgress(received: received, total: max(total, received)))
                cont.resume()
            }
        }
    }
}
