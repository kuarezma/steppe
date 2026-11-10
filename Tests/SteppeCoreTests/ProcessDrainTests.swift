import XCTest
@testable import SteppeCore

/// Wine's server and helper services inherit the output pipes of the `wine` process that started them and
/// outlive it. `ProcessRunner` must not wait for those descendants forever.
final class ProcessDrainTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private var pidFile: URL!

    /// Like wineserver: a descendant in its own session, so signals sent to the child's process group miss it.
    /// It records its pid so the test can remove it afterwards, and the command goes on only once that is done.
    private var daemon: String {
        "/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, \">\", $ARGV[0]); print F $$; close(F); sleep 25' '\(pidFile.path)' & "
            + "n=0; while [ ! -s '\(pidFile.path)' ] && [ $n -lt 200 ]; do sleep 0.05; n=$((n+1)); done;"
    }

    private var daemonPID: Int32? {
        (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0) }
    }

    override func setUp() {
        pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-daemon-\(UUID().uuidString).pid")
    }

    override func tearDown() {
        if let pid = daemonPID { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func waitForDaemon() async {
        for _ in 0..<200 where daemonPID == nil { try? await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertNotNil(daemonPID, "the descendant never started")
    }

    func testTimeoutIsReportedWhileADescendantKeepsThePipeOpen() async {
        let started = Date()
        do {
            _ = try await ProcessRunner.run(shell, arguments: ["-c", daemon + " sleep 25"], timeout: 0.5)
            XCTFail("expected a timeout")
        } catch let error as ProcessFailure {
            guard case .timedOut = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the timeout must not wait for the descendant")
        await waitForDaemon()
    }

    func testCancellationReturnsWhileADescendantKeepsThePipeOpen() async throws {
        let script = daemon + " sleep 25"
        let task = Task { try await ProcessRunner.run(self.shell, arguments: ["-c", script]) }
        await waitForDaemon()
        task.cancel()
        let started = Date()
        do {
            let result = try await task.value
            XCTFail("a cancelled command must not look like one that ran to its end (exit \(result.exitCode))")
        } catch is CancellationError {
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "cancellation must not wait for the descendant")
    }

    func testReturnsCapturedOutputAfterTheGraceWhenADescendantKeepsThePipeOpen() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(shell, arguments: ["-c", daemon + " echo started"], outputDrainGrace: 0.5)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "started")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        await waitForDaemon()
    }

    func testFindsProcessesWhenTheBundlePathIsNotCanonical() async throws {
        // The temporary directory is /var/folders/…, which the kernel reports as /private/var/folders/….
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appendingPathComponent("steppe-scan-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bundle) }
        let binary = bundle.appendingPathComponent("cossacks.exe")
        try TestSleeper.install(at: binary)
        let sleeper = Process()
        sleeper.executableURL = binary
        try sleeper.run()
        defer { sleeper.terminate() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let found = await ProcessScanner.processes(inEngine: bundle)
        XCTAssertTrue(found.contains { $0.pid == sleeper.processIdentifier })
        let running = await ProcessScanner.isGameRunning(inEngine: bundle)
        XCTAssertTrue(running)
    }

    func testLargeOutputIsCapturedCompletely() async throws {
        // More than a pipe buffer on both streams, written right before exit.
        let script = "i=0; while [ $i -lt 4000 ]; do echo 0123456789012345678901234567890123456789; echo e0123456789012345678901234567890123456789 1>&2; i=$((i+1)); done"
        let result = try await ProcessRunner.run(shell, arguments: ["-c", script])
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 4000)
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 4000)
    }
}
