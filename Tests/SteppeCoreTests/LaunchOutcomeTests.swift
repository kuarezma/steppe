import XCTest
@testable import SteppeCore

final class LaunchOutcomeTests: XCTestCase {
    private let resolution = Resolution(width: 1680, height: 945)

    func testAccessViolationIncludesResolutionInNote() throws {
        let outcome = LaunchOutcome.classify(duration: 5, logTail: "Access violation at address 00427A2B", resolution: resolution)
        XCTAssertEqual(outcome, .crashSignature(resolution))
        XCTAssertTrue(try XCTUnwrap(outcome.userNote).contains("1680×945"))
    }

    func testUnhandledPageFaultIsCrashSignature() {
        let outcome = LaunchOutcome.classify(duration: 5, logTail: "wine: Unhandled page fault on write access", resolution: resolution)
        XCTAssertEqual(outcome, .crashSignature(resolution))
        XCTAssertNotNil(outcome.userNote)
    }

    func testCleanEarlyExitHasNote() {
        let outcome = LaunchOutcome.classify(duration: 5, logTail: "Steam client exited normally", resolution: resolution)
        XCTAssertEqual(outcome, .earlyExit)
        XCTAssertNotNil(outcome.userNote)
    }

    func testLongSessionIgnoresCrashSignature() {
        let outcome = LaunchOutcome.classify(duration: 600, logTail: "00427A2B", resolution: resolution)
        XCTAssertEqual(outcome, .normal)
        XCTAssertNil(outcome.userNote)
    }

    func testThresholdIsExclusive() {
        XCTAssertEqual(LaunchOutcome.earlyExitThreshold, 15)
        XCTAssertEqual(LaunchOutcome.classify(duration: 14.999, logTail: "", resolution: resolution), .earlyExit)
        XCTAssertEqual(LaunchOutcome.classify(duration: 15, logTail: "00427A2B", resolution: resolution), .normal)
    }

    func testEachSignatureIsCaseInsensitive() {
        for signature in ["00427A2B", "ACCESS VIOLATION", "UNHANDLED PAGE FAULT", "UNHANDLED EXCEPTION"] {
            XCTAssertEqual(LaunchOutcome.classify(duration: 5, logTail: signature, resolution: resolution), .crashSignature(resolution))
        }
    }

    func testSpawnTruncatesExistingSessionLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteppePaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: paths.prefixDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.wineBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Exercise WineRunner.spawn itself without installing or launching Wine.
        try FileManager.default.createSymbolicLink(at: paths.wineBinary, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let logURL = paths.logsDir.appendingPathComponent("game-session.log")
        try Data("00427A2B".utf8).write(to: logURL)

        let process = try WineRunner(paths: paths).spawn([], environment: [:], logName: "game-session.log")
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: logURL), Data())
    }
}
