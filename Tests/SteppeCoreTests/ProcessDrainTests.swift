import XCTest
@testable import SteppeCore

private enum TestSleeper {
    static func install(at url: URL) throws {
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-x", "c", "-", "-o", url.path]
        let source = Pipe()
        compiler.standardInput = source
        try compiler.run()
        try source.fileHandleForWriting.write(contentsOf: Data("#include <unistd.h>\nint main(void) { sleep(20); return 0; }\n".utf8))
        try source.fileHandleForWriting.close()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Wine's server and helper services inherit the output pipes of the `wine` process that started them and
/// outlive it. `ProcessRunner` must not block forever waiting on those descendants.
final class ProcessDrainTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private var pidFile: URL!

    /// A descendant in its own session, like `wineserver`, so process-group kills do not reach it.
    private var daemon: String {
        "/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, \">\", $ARGV[0]); print F $$; close(F); sleep 15' '\(pidFile.path)' & "
            + "n=0; while [ ! -s '\(pidFile.path)' ] && [ $n -lt 200 ]; do sleep 0.05; n=$((n+1)); done;"
    }

    private var daemonPID: Int32? {
        (try? String(contentsOf: pidFile, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { Int32($0) }
    }

    override func setUp() {
        pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-daemon-\(UUID().uuidString).pid")
    }

    override func tearDown() {
        if let pid = daemonPID { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func waitForDaemon() async {
        for _ in 0..<200 where daemonPID == nil {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(daemonPID, "the descendant never started")
    }

    func testTimeoutIsReportedWhileADescendantKeepsThePipeOpen() async {
        let started = Date()
        do {
            _ = try await ProcessRunner.run(shell, arguments: ["-c", daemon + " sleep 15"], timeout: 0.4)
            XCTFail("expected a timeout")
        } catch let error as ProcessFailure {
            guard case .timedOut = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "timeout must not wait for descendant")
        await waitForDaemon()
    }

    func testCancellationReturnsWhileADescendantKeepsThePipeOpen() async throws {
        let script = daemon + " sleep 15"
        let shell = shell
        let task = Task { try await ProcessRunner.run(shell, arguments: ["-c", script]) }
        await waitForDaemon()
        let started = Date()
        task.cancel()
        do {
            let result = try await task.value
            XCTFail("a cancelled command must throw CancellationError, got exit \(result.exitCode)")
        } catch is CancellationError {
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "cancellation must not wait for descendant")
    }

    func testReturnsCapturedOutputAfterTheGraceWhenADescendantKeepsThePipeOpen() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(shell, arguments: ["-c", daemon + " echo hello"], outputDrainGrace: 0.3)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        await waitForDaemon()
    }

    func testFindsProcessesWhenTheBundlePathIsNotCanonical() async throws {
        // TemporaryDirectory lives under /var/folders/..., whereas the kernel proc_pidpath reports /private/var/folders/...
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appendingPathComponent("steppe-scan-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bundle) }

        let binary = bundle.appendingPathComponent("cossacks.exe")
        try TestSleeper.install(at: binary)
        let sleeper = Process()
        sleeper.executableURL = binary
        try sleeper.run()
        defer {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        let found = await ProcessScanner.processes(inEngine: bundle)
        XCTAssertTrue(found.contains { $0.pid == sleeper.processIdentifier })
        let running = await ProcessScanner.isGameRunning(inEngine: bundle)
        XCTAssertTrue(running)
    }

    func testLargeOutputIsCapturedCompletely() async throws {
        let script = "i=0; while [ $i -lt 4000 ]; do echo 0123456789012345678901234567890123456789; echo e0123456789012345678901234567890123456789 1>&2; i=$((i+1)); done"
        let result = try await ProcessRunner.run(shell, arguments: ["-c", script])
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 4000)
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 4000)
    }
}
