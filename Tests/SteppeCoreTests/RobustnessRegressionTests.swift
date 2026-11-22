import XCTest
@testable import SteppeCore

final class RobustnessRegressionTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-robust-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeSnapshot(paths: SteppePaths) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            system: SystemInfo.detect(),
            display: nil,
            displayModes: nil,
            resolution: AppSettings().customResolution,
            settings: AppSettings(),
            microphoneStatus: .notDetermined,
            stageSummary: [],
            phase: "test",
            freeBytes: 0,
            gameManifest: nil,
            paths: paths,
            leaks: []
        )
    }

    // MARK: - AppSettings resilient decode

    func testSettingsMissingKeysPreserveOtherValues() throws {
        let json = """
        {
          "preset": "quality",
          "enableSpeedPatches": false
        }
        """
        let url = dir.appendingPathComponent("settings.json")
        try Data(json.utf8).write(to: url)
        let loaded = AppSettings.load(from: url)
        XCTAssertEqual(loaded.preset, .quality)
        XCTAssertFalse(loaded.enableSpeedPatches)
        XCTAssertEqual(loaded.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(loaded.quitSteamAfterGame)
    }

    func testSettingsInvalidPresetPreservesOtherValues() throws {
        let json = """
        {
          "preset": "ultra-imaginary",
          "useCustomResolution": true,
          "enableMicrophone": true
        }
        """
        let url = dir.appendingPathComponent("settings.json")
        try Data(json.utf8).write(to: url)
        let loaded = AppSettings.load(from: url)
        XCTAssertEqual(loaded.preset, .balanced)
        XCTAssertTrue(loaded.useCustomResolution)
        XCTAssertTrue(loaded.enableMicrophone)
    }

    func testSettingsOutOfRangeResolutionIsClampedAndPreservesOtherValues() throws {
        let json = """
        {
          "customResolution": { "width": 100, "height": 99999 },
          "experimentalMathPatches": true
        }
        """
        let url = dir.appendingPathComponent("settings.json")
        try Data(json.utf8).write(to: url)
        let loaded = AppSettings.load(from: url)
        XCTAssertEqual(loaded.customResolution, Resolution(width: AppSettings.widthRange.lowerBound, height: AppSettings.heightRange.upperBound))
        XCTAssertTrue(loaded.experimentalMathPatches)
    }

    func testSettingsWithAWronglyTypedValueKeepTheOthers() throws {
        let json = """
        {
          "preset": "performance",
          "enableSpeedPatches": "not-a-bool",
          "recordFrameTimes": true,
          "multithreadedEngine": false
        }
        """
        let url = dir.appendingPathComponent("settings.json")
        try Data(json.utf8).write(to: url)
        let loaded = AppSettings.load(from: url)
        XCTAssertEqual(loaded.preset, .performance)
        XCTAssertTrue(loaded.enableSpeedPatches)
        XCTAssertTrue(loaded.recordFrameTimes)
        XCTAssertFalse(loaded.multithreadedEngine)
    }

    func testSettingsRoundTripAndInvalidFile() throws {
        let url = dir.appendingPathComponent("settings.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(AppSettings.load(from: url), AppSettings())

        var settings = AppSettings()
        settings.preset = .native
        settings.enableNotchHUD = false
        try settings.save(to: url)
        XCTAssertEqual(AppSettings.load(from: url), settings)
    }

    // MARK: - Diagnostics tail & UTF-8

    func testDiagnosticsIncludesInvalidUTF8Log() throws {
        let paths = SteppePaths(root: dir)
        try paths.ensureDirectories()
        var bytes = Data([0xFF, 0xFE])
        bytes.append(Data("\nunhandled page fault at 00427a2b\n".utf8))
        try bytes.write(to: paths.logsDir.appendingPathComponent("game-session.log"))
        let report = Diagnostics.report(for: makeSnapshot(paths: paths))
        XCTAssertTrue(report.contains("game-session.log (last lines):"))
        XCTAssertTrue(report.contains("unhandled page fault at 00427a2b"))
    }

    func testDiagnosticsReadsOnlyLogEnd() throws {
        let paths = SteppePaths(root: dir)
        try paths.ensureDirectories()
        let text = "first-unique-marker\n" + String(repeating: "x", count: 270_000) + "\nlast-unique-marker\n"
        try Data(text.utf8).write(to: paths.logsDir.appendingPathComponent("game-session.log"))
        let report = Diagnostics.report(for: makeSnapshot(paths: paths))
        XCTAssertTrue(report.contains("last-unique-marker"))
        XCTAssertFalse(report.contains("first-unique-marker"))
    }

    // MARK: - ProfileTuner unreadable profile skip

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

    // MARK: - Unpinned downloader partial reset

    func testUnpinnedDownloadsNeverResumePartialFilesAndPinnedStillResumes() async throws {
        final class RobustStubServer: URLProtocol {
            private final class State: @unchecked Sendable {
                private let lock = NSLock()
                private var cutAfter: Int? = nil
                private var requestedRanges: [String?] = []

                func reset(cutAfter: Int?) {
                    lock.lock()
                    self.cutAfter = cutAfter
                    self.requestedRanges = []
                    lock.unlock()
                }

                func snapshotRanges() -> [String?] {
                    lock.lock(); defer { lock.unlock() }; return requestedRanges
                }

                func recordRequest(range: String?) -> Int? {
                    lock.lock()
                    defer { lock.unlock() }
                    requestedRanges.append(range)
                    let cut = cutAfter
                    if cut != nil { cutAfter = nil }
                    return cut
                }
            }

            static let payload = Data((0..<120_000).map { UInt8($0 % 227) })
            private static let state = State()

            static func reset(cutAfter: Int?) {
                state.reset(cutAfter: cutAfter)
            }

            static var requestedRanges: [String?] {
                state.snapshotRanges()
            }

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func stopLoading() {}

            override func startLoading() {
                let url = request.url!
                let payload = Self.payload
                let cut = Self.state.recordRequest(range: request.value(forHTTPHeaderField: "Range"))
                var start = 0
                var status = 200
                var headers = ["Content-Length": "\(payload.count)"]
                if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="),
                   let offset = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
                    start = offset
                    status = 206
                    headers["Content-Length"] = "\(payload.count - start)"
                }
                let body = payload.subdata(in: start..<payload.count)
                if let cut {
                    final class ProtocolBox: @unchecked Sendable {
                        let proto: RobustStubServer
                        init(_ proto: RobustStubServer) { self.proto = proto }
                    }
                    let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(body.prefix(cut)))
                    let box = ProtocolBox(self)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
                        box.proto.client?.urlProtocol(box.proto, didFailWithError: URLError(.networkConnectionLost))
                    }
                    return
                }
                let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        let url = URL(string: "https://example.invalid/file.bin")!
        let makeCfg: () -> URLSessionConfiguration = {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [RobustStubServer.self]
            return c
        }

        // 1. Pre-existing .part is discarded for unpinned downloads.
        RobustStubServer.reset(cutAfter: nil)
        let dest1 = dir.appendingPathComponent("unpinned1.bin")
        try Data(repeating: 0xAA, count: 1000).write(to: dest1.appendingPathExtension("part"))
        try await Downloader.download(
            url: url,
            to: dest1,
            expectedSHA256: nil,
            expectedSize: nil,
            configuration: makeCfg(),
            retryDelayUnit: 1_000_000
        ) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest1), RobustStubServer.payload)
        XCTAssertEqual(RobustStubServer.requestedRanges.count, 1)
        XCTAssertNil(RobustStubServer.requestedRanges.first ?? "non-nil")

        // 2. Retry after drop also restarts from byte 0 when unpinned.
        RobustStubServer.reset(cutAfter: 40_000)
        let dest2 = dir.appendingPathComponent("unpinned2.bin")
        try await Downloader.download(
            url: url,
            to: dest2,
            expectedSHA256: nil,
            expectedSize: nil,
            configuration: makeCfg(),
            retryDelayUnit: 1_000_000
        ) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest2), RobustStubServer.payload)
        XCTAssertEqual(RobustStubServer.requestedRanges.count, 2)
        XCTAssertTrue(RobustStubServer.requestedRanges.allSatisfy { $0 == nil })

        // 3. Pinned downloads still resume via Range.
        RobustStubServer.reset(cutAfter: nil)
        let dest3 = dir.appendingPathComponent("pinned.bin")
        try Data(RobustStubServer.payload.prefix(1000)).write(to: dest3.appendingPathExtension("part"))
        try await Downloader.download(
            url: url,
            to: dest3,
            expectedSHA256: Hashing.sha256(of: RobustStubServer.payload),
            expectedSize: Int64(RobustStubServer.payload.count),
            configuration: makeCfg(),
            retryDelayUnit: 1_000_000
        ) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest3), RobustStubServer.payload)
        XCTAssertTrue(RobustStubServer.requestedRanges.contains { $0 == "bytes=1000-" })
    }
}
