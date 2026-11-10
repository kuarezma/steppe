import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessFailure: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(String)
    case nonZeroExit(String, CommandResult)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return L("Could not start %@", m)
        case .timedOut(let m): return L("%@ did not finish in time", m)
        case .nonZeroExit(let m, let r):
            return L("%@ failed (exit %d)", m, r.exitCode) + ": " + String(r.stderr.suffix(400))
        }
    }
}

private final class Accumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var sealed = false
    private var reachedEOF = false
    func append(_ chunk: Data) { lock.lock(); if !sealed { data.append(chunk) }; lock.unlock() }
    /// Returns the captured text and frees it; anything that arrives later is dropped. The reader can live on
    /// for as long as a descendant keeps the pipe open, so it must not keep the output alive with it.
    func seal() -> String {
        lock.lock(); defer { lock.unlock() }
        sealed = true
        let text = String(decoding: data, as: UTF8.self)
        data = Data()
        return text
    }
    /// True the first time only, so end-of-file is counted once.
    func markEOF() -> Bool { lock.lock(); defer { lock.unlock() }; if reachedEOF { return false }; reachedEOF = true; return true }
}

public enum ProcessRunner {
    /// Runs a command to completion. Output is captured; on timeout or task cancellation the process is killed
    /// and the call throws `ProcessFailure.timedOut` or `CancellationError`, never the exit status of the kill.
    ///
    /// Descendants that outlive the command (wineserver and Wine's services inherit its pipes) keep the pipes open.
    /// After the command exits its output is awaited for at most `outputDrainGrace` seconds, and not at all once
    /// it timed out or was cancelled, so such a descendant can never hold this call hostage.
    @discardableResult
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        outputDrainGrace: TimeInterval = 15
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let label = executable.lastPathComponent
        let timedOut = Flag(), cancelled = Flag()
        // A task that was cancelled before we got here must not start anything.
        if Task.isCancelled { throw CancellationError() }

        let out = Accumulator(), err = Accumulator()
        let streams = [(outPipe, out), (errPipe, err)]
        let drained = DispatchGroup()
        @Sendable func stopReading(_ pipe: Pipe, _ accumulator: Accumulator) {
            pipe.fileHandleForReading.readabilityHandler = nil
            if accumulator.markEOF() { drained.leave() }
        }
        for (pipe, accumulator) in streams {
            drained.enter()
            // Capturing the pipe keeps it open until end-of-file, also after this call has returned: a descendant
            // that still writes to it must not meet a closed pipe.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { stopReading(pipe, accumulator) } else { accumulator.append(chunk) }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { proc in
                    DispatchQueue.global().async {
                        let deadline = Date().addingTimeInterval(outputDrainGrace)
                        while drained.wait(timeout: .now() + 0.05) == .timedOut {
                            if timedOut.value || cancelled.value || Date() >= deadline { break }
                        }
                        let stdout = out.seal(), stderr = err.seal()
                        if timedOut.value {
                            continuation.resume(throwing: ProcessFailure.timedOut(label))
                        } else if cancelled.value {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: CommandResult(exitCode: proc.terminationStatus, stdout: stdout, stderr: stderr))
                        }
                    }
                }
                do {
                    try process.run()
                } catch {
                    for (pipe, accumulator) in streams { stopReading(pipe, accumulator) }
                    continuation.resume(throwing: ProcessFailure.launchFailed("\(label): \(error.localizedDescription)"))
                    return
                }
                // Cancellation can arrive between the check above and `run()`; stop the fresh process right away.
                if Task.isCancelled {
                    cancelled.set()
                    Self.stop(process)
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        timedOut.set()
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
            }
        } onCancel: {
            cancelled.set()
            Self.stop(process)
        }
    }

    /// SIGTERM first, SIGKILL if the process ignores it.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Like `run`, but throws if the exit status is not 0.
    @discardableResult
    public static func runChecked(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> CommandResult {
        let result = try await run(executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout)
        guard result.succeeded else {
            throw ProcessFailure.nonZeroExit(executable.lastPathComponent, result)
        }
        return result
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

/// A process on the system, as reported by `ps`.
public struct RunningProcess: Sendable, Equatable {
    public let pid: Int32
    /// Wine rewrites this to the Windows image path, for example `C:\Steam\steam.exe`.
    public let command: String

    /// File name of the (Windows or macOS) image, lower-cased.
    public var imageName: String {
        let lastSlash = command.lastIndex(where: { $0 == "\\" || $0 == "/" })
        let name = lastSlash.map { command[command.index(after: $0)...] } ?? Substring(command)
        return name.lowercased()
    }
}

public enum ProcessScanner {
    /// All processes of the current user.
    public static func list() async -> [RunningProcess] {
        guard let result = try? await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,comm=", "-U", String(getuid())],
            timeout: 15
        ), result.succeeded else { return [] }
        return parse(result.stdout)
    }

    static func parse(_ output: String) -> [RunningProcess] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[trimmed.startIndex..<space]) else { return nil }
            return RunningProcess(pid: pid, command: String(trimmed[trimmed.index(after: space)...]))
        }
    }

    /// Real path of the executable a process was started from.
    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Processes started from our Wine engine. Wine rewrites the process title of its children, so the
    /// environment is not visible; the executable path is what reliably tells them apart from other Wine installs.
    public static func processes(inEngine bundle: URL) async -> [RunningProcess] {
        // proc_pidpath reports the canonical path, so match the symlink-resolved bundle path too. `realpath` is
        // needed as well: `resolvingSymlinksInPath` drops the /private prefix the kernel reports for /var and /tmp.
        var candidates = [bundle.path, bundle.resolvingSymlinksInPath().path]
        if let real = realpath(bundle.path, nil) {
            candidates.append(String(cString: real))
            free(real)
        }
        let prefixes = candidates.map { $0.precomposedStringWithCanonicalMapping + "/" }
        let me = getpid()
        return await list().filter { process in
            guard process.pid != me, let path = executablePath(of: process.pid) else { return false }
            let canonical = path.precomposedStringWithCanonicalMapping
            return prefixes.contains { canonical.hasPrefix($0) }
        }
    }

    public static func isGameRunning(inEngine bundle: URL) async -> Bool {
        await processes(inEngine: bundle).contains { $0.imageName == "cossacks.exe" }
    }
}
