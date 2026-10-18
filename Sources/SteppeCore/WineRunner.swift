import Darwin
import Foundation

/// Starts and stops Wine processes for one prefix.
public struct WineRunner: Sendable {
    public let paths: SteppePaths

    public init(paths: SteppePaths) {
        self.paths = paths
    }

    /// Runs `wine <arguments>` to completion.
    @discardableResult
    public func run(_ arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> CommandResult {
        try await ProcessRunner.run(paths.wineBinary, arguments: arguments, environment: environment, currentDirectory: paths.prefixDir, timeout: timeout)
    }

    /// Like `run`, but throws when Wine exits with a non-zero status.
    @discardableResult
    public func runChecked(_ arguments: [String], environment: [String: String], timeout: TimeInterval?) async throws -> CommandResult {
        try await ProcessRunner.runChecked(paths.wineBinary, arguments: arguments, environment: environment, currentDirectory: paths.prefixDir, timeout: timeout)
    }

    /// Starts `wine <arguments>` without waiting. Output goes to `logName` inside the logs folder.
    @discardableResult
    public func spawn(_ arguments: [String], environment: [String: String], logName: String) throws -> Process {
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        let logURL = paths.logsDir.appendingPathComponent(logName)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = paths.wineBinary
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = paths.prefixDir
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Waits until every process of the prefix has exited (`wineserver -w`).
    public func waitForIdle(environment: [String: String], timeout: TimeInterval) async {
        _ = try? await ProcessRunner.run(paths.wineserverBinary, arguments: ["-w"], environment: environment, timeout: timeout)
    }

    /// Stops the prefix: polite `wineserver -k`, then SIGKILL for anything of this prefix that survives.
    public func killAll(environment: [String: String]) async {
        _ = try? await ProcessRunner.run(paths.wineserverBinary, arguments: ["-k"], environment: environment, timeout: 20)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for process in await ProcessScanner.processes(inEngine: paths.wineBundle) {
            Log.shared.warn("Force-stopping leftover process \(process.pid)")
            kill(process.pid, SIGKILL)
        }
    }

    public func isAnyProcessRunning() async -> Bool {
        !(await ProcessScanner.processes(inEngine: paths.wineBundle)).isEmpty
    }
}
