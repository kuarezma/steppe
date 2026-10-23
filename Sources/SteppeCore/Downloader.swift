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
                // Non-transient answers are not retried.
                if case .badStatus(let code) = error, code != 429, code < 500 { throw error }
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
        var existing = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        if let expectedSize, existing > expectedSize {
            try? fm.removeItem(at: part)
            existing = 0
        }
        if let expectedSize, existing == expectedSize { return }

        var request = URLRequest(url: url)
        request.setValue("Steppe", forHTTPHeaderField: "User-Agent")
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let delegate = DownloadDelegate(part: part, resumeOffset: existing, progress: progress)
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
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let part: URL
    var resumeOffset: Int64
    let progress: @Sendable (DownloadProgress) -> Void
    var continuation: CheckedContinuation<Void, Error>?

    private var handle: FileHandle?
    private var received: Int64
    private var total: Int64 = 0
    private var lastReport = Date.distantPast
    private var failure: Error?

    init(part: URL, resumeOffset: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.part = part
        self.resumeOffset = resumeOffset
        self.received = resumeOffset
        self.progress = progress
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = DownloadError.network("Unexpected response")
            return completionHandler(.cancel)
        }
        let fm = FileManager.default
        switch http.statusCode {
        case 206:
            total = resumeOffset + http.expectedContentLength
        case 200:
            // Server ignored the range request: start over.
            resumeOffset = 0
            received = 0
            total = http.expectedContentLength
            try? fm.removeItem(at: part)
        case 416:
            // Our partial file is unusable; discard and let the caller retry.
            try? fm.removeItem(at: part)
            failure = DownloadError.badStatus(503)
            return completionHandler(.cancel)
        default:
            failure = DownloadError.badStatus(http.statusCode)
            return completionHandler(.cancel)
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
        let cont = continuation
        continuation = nil
        if let failure {
            cont?.resume(throwing: failure)
        } else if let error {
            cont?.resume(throwing: error)
        } else {
            progress(DownloadProgress(received: received, total: max(total, received)))
            cont?.resume()
        }
    }
}
