import Foundation
import XCTest
@testable import SteppeCore

final class RobustnessRegressionTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-robust-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        StubServer.payload = Data((0..<200_000).map { UInt8($0 % 251) })
        StubServer.failuresRemaining = 0
        StubServer.ignoreRange = false
        StubServer.cutAfter = nil
        StubServer.requestedRanges = []
        StubServer.corruptNextResponse = false
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func load(_ json: String) throws -> AppSettings {
        let url = dir.appendingPathComponent("settings.json")
        try Data(json.utf8).write(to: url)
        return AppSettings.load(from: url)
    }

    private var nonDefaultSettings: AppSettings {
        var settings = AppSettings()
        settings.preset = .quality
        settings.customResolution = Resolution(width: 1920, height: 1080)
        settings.useCustomResolution = true
        settings.quitSteamAfterGame = false
        settings.experimentalMathPatches = true
        settings.recordFrameTimes = true
        return settings
    }

    func testSettingsMissingKeysPreserveOtherValues() throws {
        var expected = AppSettings()
        expected.preset = .quality
        expected.useCustomResolution = true
        XCTAssertEqual(try load(#"{"preset":"quality","useCustomResolution":true}"#), expected)
    }

    func testSettingsInvalidPresetPreservesOtherValues() throws {
        let json = #"{"preset":"ultra","customResolution":{"width":1920,"height":1080},"useCustomResolution":true,"quitSteamAfterGame":false,"experimentalMathPatches":true,"recordFrameTimes":true}"#
        var expected = nonDefaultSettings
        expected.preset = .balanced
        XCTAssertEqual(try load(json), expected)
    }

    func testSettingsInvalidResolutionPreservesOtherValues() throws {
        for resolution in [#"{"width":0,"height":0}"#, #"{"width":16385,"height":1080}"#, #"{"width":1920,"height":16385}"#, #"{"width":1024,"height":575}"#] {
            let settings = try load("{\"preset\":\"quality\",\"useCustomResolution\":true,\"quitSteamAfterGame\":true,\"experimentalMathPatches\":false,\"recordFrameTimes\":false,\"customResolution\":\(resolution)}")
            XCTAssertEqual(settings.customResolution, AppSettings().customResolution)
            XCTAssertEqual(settings.preset, .quality)
            XCTAssertTrue(settings.useCustomResolution)
        }
    }

    func testSettingsRoundTripAndInvalidFile() throws {
        let url = dir.appendingPathComponent("settings.json")
        XCTAssertEqual(AppSettings.load(from: url), AppSettings())
        try Data("garbage".utf8).write(to: url)
        XCTAssertEqual(AppSettings.load(from: url), AppSettings())
        try nonDefaultSettings.save(to: url)
        XCTAssertEqual(AppSettings.load(from: url), nonDefaultSettings)
    }

    private var snapshot: DiagnosticsSnapshot {
        DiagnosticsSnapshot(system: SystemInfo.detect(), display: nil, displayModes: nil,
                            resolution: AppSettings().customResolution, settings: AppSettings(),
                            microphoneStatus: .notDetermined, stageSummary: [], phase: "test",
                            freeBytes: 0, gameManifest: nil, paths: SteppePaths(root: dir), leaks: [])
    }

    func testDiagnosticsIncludesInvalidUTF8Log() throws {
        let paths = SteppePaths(root: dir)
        try paths.ensureDirectories()
        var bytes = Data([0xFF, 0xFE])
        bytes.append(Data("\nunhandled page fault at 00427a2b\n".utf8))
        try bytes.write(to: paths.logsDir.appendingPathComponent("game-session.log"))
        let report = Diagnostics.report(for: snapshot)
        XCTAssertTrue(report.contains("game-session.log (last lines):"))
        XCTAssertTrue(report.contains("unhandled page fault at 00427a2b"))
    }

    func testDiagnosticsReadsOnlyLogEnd() throws {
        let paths = SteppePaths(root: dir)
        try paths.ensureDirectories()
        let text = "first-unique-marker\n" + String(repeating: "x", count: 270_000) + "\nlast-unique-marker\n"
        try Data(text.utf8).write(to: paths.logsDir.appendingPathComponent("game-session.log"))
        let report = Diagnostics.report(for: snapshot)
        XCTAssertTrue(report.contains("last-unique-marker"))
        XCTAssertFalse(report.contains("first-unique-marker"))
    }

    func testTunerContinuesAfterUnreadableProfile() throws {
        let a = dir.appendingPathComponent("A/profile.cfg")
        let b = dir.appendingPathComponent("B/profile.cfg")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(ProfileConfigTests.sample.utf8).write(to: b)
        let resolution = Resolution(width: 1280, height: 720)
        let outcome = try ProfileTuner.apply(resolution: resolution, profilesDir: dir)
        XCTAssertEqual(outcome.skipped, ["A"])
        XCTAssertEqual(outcome.updated, ["B"])
        XCTAssertEqual(ProfileConfig.screenResolution(in: try String(contentsOf: b, encoding: .isoLatin1)), resolution)
    }

    private var config: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return config
    }

    func testUnpinnedDownloadDiscardsPreviousPartial() async throws {
        let dest = dir.appendingPathComponent("out.bin")
        try Data(repeating: 0xAA, count: 1000).write(to: dest.appendingPathExtension("part"))
        try await Downloader.download(url: URL(string: "https://example.invalid/file.bin")!, to: dest,
                                      expectedSHA256: nil, expectedSize: nil, configuration: config,
                                      retryDelayUnit: 1_000_000) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest), StubServer.payload)
        XCTAssertEqual(StubServer.requestedRanges.count, 1)
        XCTAssertNil(StubServer.requestedRanges.first!)
    }

    func testUnpinnedDownloadStartsOverAfterAConnectionDrop() async throws {
        StubServer.cutAfter = 50_000
        let dest = dir.appendingPathComponent("out.bin")
        try await Downloader.download(url: URL(string: "https://example.invalid/file.bin")!, to: dest,
                                      expectedSHA256: nil, expectedSize: nil, configuration: config,
                                      retryDelayUnit: 1_000_000) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest), StubServer.payload)
        XCTAssertEqual(StubServer.requestedRanges.count, 2)
        XCTAssertTrue(StubServer.requestedRanges.allSatisfy { $0 == nil }, "no attempt may resume: \(StubServer.requestedRanges)")
    }

    func testPinnedDownloadResumesPreviousPartial() async throws {
        let dest = dir.appendingPathComponent("out.bin")
        try Data(StubServer.payload.prefix(1000)).write(to: dest.appendingPathExtension("part"))
        try await Downloader.download(url: URL(string: "https://example.invalid/file.bin")!, to: dest,
                                      expectedSHA256: Hashing.sha256(of: StubServer.payload),
                                      expectedSize: Int64(StubServer.payload.count), configuration: config,
                                      retryDelayUnit: 1_000_000) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest), StubServer.payload)
        XCTAssertTrue(StubServer.requestedRanges.contains { $0 == "bytes=1000-" })
    }
}
