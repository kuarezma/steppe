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
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

public enum ProcessRunner {
    /// Runs a command to completion. Output is captured; the process is killed on timeout or task cancellation.
    @discardableResult
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
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
        let out = Accumulator(), err = Accumulator()
        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

        let label = executable.lastPathComponent
        let timedOut = TimeoutFlag()
        // A task that was cancelled before we got here must not start anything.
        if Task.isCancelled {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw CancellationError()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    if timedOut.value {
                        continuation.resume(throwing: ProcessFailure.timedOut(label))
                    } else {
                        continuation.resume(returning: CommandResult(exitCode: proc.terminationStatus, stdout: out.text(), stderr: err.text()))
                    }
                }
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ProcessFailure.launchFailed("\(label): \(error.localizedDescription)"))
                    return
                }
                // Cancellation can arrive between the check above and `run()`; stop the fresh process right away.
                if Task.isCancelled { Self.stop(process) }
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

private final class TimeoutFlag: @unchecked Sendable {
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
        // proc_pidpath reports the canonical path, so match the symlink-resolved bundle path too.
        let prefixes = [bundle.path, bundle.resolvingSymlinksInPath().path].map { $0.precomposedStringWithCanonicalMapping + "/" }
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
