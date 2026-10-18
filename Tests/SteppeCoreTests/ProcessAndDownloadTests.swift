import XCTest
@testable import SteppeCore

final class ProcessRunnerTests: XCTestCase {
    func testCapturesOutputAndExitCode() async throws {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err 1>&2; exit 3"])
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
    }

    func testTimeoutKillsTheProcess() async {
        do {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.5)
            XCTFail("expected a timeout")
        } catch let error as ProcessFailure {
            guard case .timedOut = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testAlreadyCancelledTaskNeverStartsTheProcess() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path])
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationStopsAProcessThatIgnoresSIGTERM() async throws {
        let script = "trap '' TERM; while true; do sleep 1; done"
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        let started = Date()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "SIGKILL escalation must end the process")
    }

    func testRunCheckedThrowsOnFailure() async {
        do {
            _ = try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/false"))
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error is ProcessFailure)
        }
    }

    func testPsParsingAndImageName() {
        let parsed = ProcessScanner.parse("  101 /bin/zsh\n  2002 C:\\Steam\\steamapps\\common\\Cossacks 3\\cossacks.exe\n")
        XCTAssertEqual(parsed.map(\.pid), [101, 2002])
        XCTAssertEqual(parsed[0].imageName, "zsh")
        XCTAssertEqual(parsed[1].imageName, "cossacks.exe")
    }

    func testFindsProcessesByExecutablePath() async throws {
        // `sleep` runs from /bin, so scanning /bin must find it and scanning an unrelated folder must not.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["20"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let hit = await ProcessScanner.processes(inEngine: URL(fileURLWithPath: "/bin"))
        XCTAssertTrue(hit.contains { $0.pid == sleeper.processIdentifier })
        let miss = await ProcessScanner.processes(inEngine: URL(fileURLWithPath: "/nonexistent-engine"))
        XCTAssertTrue(miss.isEmpty)
    }

    func testLaunchFailureIsReported() async {
        do {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/binary"))
            XCTFail("expected failure")
        } catch let error as ProcessFailure {
            guard case .launchFailed = error else { return XCTFail("wrong error \(error)") }
        } catch { XCTFail("\(error)") }
    }
}

/// Serves a fixed payload and honours `Range` requests; can be told to fail the first N requests.
final class StubServer: URLProtocol {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var failuresRemaining = 0
    nonisolated(unsafe) static var ignoreRange = false
    nonisolated(unsafe) static var cutAfter: Int? = nil
    nonisolated(unsafe) static var requestedRanges: [String?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        Self.requestedRanges.append(request.value(forHTTPHeaderField: "Range"))
        if Self.failuresRemaining > 0 {
            Self.failuresRemaining -= 1
            send(status: 503, headers: [:], body: Data())
            return
        }
        var start = 0
        var status = 200
        var headers = ["Content-Length": "\(Self.payload.count)"]
        if !Self.ignoreRange, let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="),
           let s = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            start = s
            status = 206
            headers["Content-Length"] = "\(Self.payload.count - start)"
        }
        var body = Self.payload.subdata(in: start..<Self.payload.count)
        if let cut = Self.cutAfter, status == 200 || start == 0 {
            Self.cutAfter = nil
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.prefix(cut)))
            // A real connection drop happens after the bytes already arrived; give the delegate time to consume them.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        send(status: status, headers: headers, body: body)
        body = Data()
    }

    private func send(status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class DownloaderTests: XCTestCase {
    private var dir: URL!
    private let url = URL(string: "https://example.invalid/file.bin")!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-dl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        StubServer.payload = Data((0..<200_000).map { UInt8($0 % 251) })
        StubServer.failuresRemaining = 0
        StubServer.ignoreRange = false
        StubServer.cutAfter = nil
        StubServer.requestedRanges = []
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private var config: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        return c
    }

    private func fetch(sha: String? = nil, size: Int64? = nil, attempts: Int = 5) async throws -> URL {
        let dest = dir.appendingPathComponent("out.bin")
        try await Downloader.download(url: url, to: dest, expectedSHA256: sha ?? Hashing.sha256(of: StubServer.payload),
                                      expectedSize: size ?? Int64(StubServer.payload.count), maxAttempts: attempts,
                                      configuration: config, retryDelayUnit: 1_000_000) { _ in }
        return dest
    }

    func testDownloadsAndVerifies() async throws {
        let dest = try await fetch()
        XCTAssertEqual(try Data(contentsOf: dest), StubServer.payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathExtension("part").path))
    }

    func testRetriesTransientServerErrors() async throws {
        StubServer.failuresRemaining = 2
        let dest = try await fetch()
        XCTAssertEqual(try Data(contentsOf: dest), StubServer.payload)
    }

    func testResumesAfterConnectionDrop() async throws {
        StubServer.cutAfter = 50_000
        let dest = try await fetch()
        XCTAssertEqual(try Data(contentsOf: dest), StubServer.payload)
        XCTAssertTrue(StubServer.requestedRanges.contains { ($0 ?? "").hasPrefix("bytes=") }, "second attempt must resume with a Range header, got \(StubServer.requestedRanges)")
    }

    func testRestartsWhenServerIgnoresRange() async throws {
        StubServer.cutAfter = 30_000
        StubServer.ignoreRange = true
        let dest = try await fetch()
        XCTAssertEqual(try Data(contentsOf: dest), StubServer.payload)
    }

    func testRejectsWrongChecksum() async {
        do {
            _ = try await fetch(sha: String(repeating: "0", count: 64))
            XCTFail("expected checksum failure")
        } catch DownloadError.checksumMismatch {
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out.bin").path))
    }

    func testRejectsWrongSize() async {
        do {
            _ = try await fetch(size: 5)
            XCTFail("expected size failure")
        } catch DownloadError.sizeMismatch {
        } catch { XCTFail("wrong error \(error)") }
    }

    func testClientErrorsAreNotRetried() async {
        StubServer.failuresRemaining = 0
        let dest = dir.appendingPathComponent("x.bin")
        final class Always404: URLProtocol {
            nonisolated(unsafe) static var hits = 0
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Always404.hits += 1
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Always404.self]
        do {
            try await Downloader.download(url: url, to: dest, expectedSHA256: nil, expectedSize: nil, configuration: c, retryDelayUnit: 1_000_000) { _ in }
            XCTFail("expected 404")
        } catch DownloadError.badStatus(let code) {
            XCTAssertEqual(code, 404)
            XCTAssertEqual(Always404.hits, 1)
        } catch { XCTFail("wrong error \(error)") }
    }
}

final class SystemInfoTests: XCTestCase {
    func testFreeBytesWorksForExistingAndMissingPaths() {
        let tmp = FileManager.default.temporaryDirectory
        XCTAssertGreaterThan(SystemInfo.freeBytes(at: tmp), 0)
        XCTAssertGreaterThan(SystemInfo.freeBytes(at: tmp.appendingPathComponent("does/not/exist/yet")), 0)
    }

    func testFreeBytesWorksOnExternalVolumeWhenMounted() throws {
        let volumes = try FileManager.default.contentsOfDirectory(atPath: "/Volumes")
            .filter { $0 != "Macintosh HD" }
        try XCTSkipIf(volumes.isEmpty, "no external volume mounted")
        for name in volumes {
            let free = SystemInfo.freeBytes(at: URL(fileURLWithPath: "/Volumes/\(name)"))
            XCTAssertGreaterThanOrEqual(free, 0)
        }
    }
}
