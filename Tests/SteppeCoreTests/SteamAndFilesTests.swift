import XCTest
@testable import SteppeCore

final class SteamACFTests: XCTestCase {
    static let acf = """
    "AppState"
    {
    \t"appid"\t\t"333420"
    \t"LastOwner"\t\t"76561198000000000"
    \t"installdir"\t\t"Cossacks 3"
    \t"StateFlags"\t\t"4"
    \t"SizeOnDisk"\t\t"8786332818"
    \t"BytesToDownload"\t\t"1000"
    \t"BytesDownloaded"\t\t"250"
    }
    """

    func testParsesTheFieldsWeNeed() throws {
        let info = try XCTUnwrap(SteamACF.parse(Self.acf))
        XCTAssertEqual(info.stateFlags, 4)
        XCTAssertTrue(info.isFullyInstalled)
        XCTAssertEqual(info.installDir, "Cossacks 3")
        XCTAssertEqual(info.sizeOnDisk, 8_786_332_818)
        XCTAssertEqual(try XCTUnwrap(info.downloadFraction), 0.25, accuracy: 0.0001)
    }

    func testDownloadingStateIsNotInstalled() throws {
        let info = try XCTUnwrap(SteamACF.parse(Self.acf.replacingOccurrences(of: "\"4\"", with: "\"1026\"")))
        XCTAssertFalse(info.isFullyInstalled)
    }

    func testRejectsGarbage() {
        XCTAssertNil(SteamACF.parse("not a manifest"))
    }
}

final class GameFilesTests: XCTestCase {
    private func makeDirs() throws -> (src: URL, game: URL, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-files-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src"), game = base.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        return (src, game, { try? FileManager.default.removeItem(at: base) })
    }

    func testReplacesVerifiedOriginalsOnlyAndKeepsBackup() throws {
        let (src, game, cleanup) = try makeDirs()
        defer { cleanup() }
        for name in GameFiles.libraryNames {
            try Data("ours-\(name)".utf8).write(to: src.appendingPathComponent(name))
            try Data("orig-\(name)".utf8).write(to: game.appendingPathComponent(name))
        }
        var known: [String: String] = [:]
        for name in GameFiles.libraryNames { known[name] = Hashing.sha256(of: Data("orig-\(name)".utf8)) }

        let first = GameFiles.installSpeedLibraries(from: src, into: game, knownOriginals: known)
        XCTAssertEqual(first.filter { if case .installed = $0 { return true } else { return false } }.count, 3)
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("ogg.dll")), "ours-ogg.dll")
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("ogg.dll.steppe-orig")), "orig-ogg.dll")

        let second = GameFiles.installSpeedLibraries(from: src, into: game, knownOriginals: known)
        XCTAssertTrue(second.allSatisfy { if case .alreadyCurrent = $0 { return true } else { return false } })

        XCTAssertEqual(GameFiles.restoreOriginals(in: game), 3)
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("vorbis.dll")), "orig-vorbis.dll")
    }

    func testLeavesUnknownFilesAlone() throws {
        let (src, game, cleanup) = try makeDirs()
        defer { cleanup() }
        for name in GameFiles.libraryNames {
            try Data("ours".utf8).write(to: src.appendingPathComponent(name))
            try Data("newer game build".utf8).write(to: game.appendingPathComponent(name))
        }
        let known = Dictionary(uniqueKeysWithValues: GameFiles.libraryNames.map { ($0, "deadbeef") })
        let results = GameFiles.installSpeedLibraries(from: src, into: game, knownOriginals: known)
        XCTAssertTrue(results.allSatisfy { if case .skippedUnknownFile = $0 { return true } else { return false } })
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("ogg.dll")), "newer game build")
    }
}

final class PrefixIsolationTests: XCTestCase {
    func testIsolateRemovesHostMappingsAndSymlinks() throws {
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent("steppe-prefix-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: prefix) }
        let dos = prefix.appendingPathComponent("dosdevices")
        let userDir = prefix.appendingPathComponent("drive_c/users/steppe")
        try fm.createDirectory(at: dos, withIntermediateDirectories: true)
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dos.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(at: dos.appendingPathComponent("z:"), withDestinationURL: URL(fileURLWithPath: "/"))
        try fm.createSymbolicLink(at: userDir.appendingPathComponent("Documents"), withDestinationURL: URL(fileURLWithPath: NSHomeDirectory()))
        try fm.createDirectory(at: userDir.appendingPathComponent("AppData"), withIntermediateDirectories: true)

        XCTAssertEqual(Set(PrefixBuilder.escapesPrefix(prefix: prefix)), ["dosdevices/z:", "users/steppe/Documents"])
        try PrefixBuilder.isolate(prefix: prefix)
        XCTAssertTrue(PrefixBuilder.escapesPrefix(prefix: prefix).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: dos.appendingPathComponent("c:").path), "C: must stay")
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: userDir.appendingPathComponent("Documents").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        // The Mac home directory itself must be untouched.
        XCTAssertTrue(fm.fileExists(atPath: NSHomeDirectory()))
    }
}

final class WinePatcherTests: XCTestCase {
    private typealias P = RuntimeManifest.BytePatch

    func testAppliesPatchesAtOffsets() throws {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let out = try WinePatcher.applyBytes(data, patches: [P(offset: 2, expected: [2, 3], replacement: [0x90, 0x90], note: "")])
        XCTAssertEqual([UInt8](out), [0, 1, 0x90, 0x90, 4, 5, 6, 7])
    }

    func testRejectsUnexpectedBytes() {
        let data = Data([0, 1, 2, 3])
        XCTAssertThrowsError(try WinePatcher.applyBytes(data, patches: [P(offset: 1, expected: [9], replacement: [0], note: "")])) {
            XCTAssertEqual($0 as? WinePatchError, .bytesDiffer(offset: 1))
        }
    }

    func testRejectsOutOfRange() {
        XCTAssertThrowsError(try WinePatcher.applyBytes(Data([1]), patches: [P(offset: 5, expected: [1], replacement: [2], note: "")]))
    }

    func testManifestIsWellFormed() {
        let m = RuntimeManifest.current
        for hash in [m.engine.sha256, m.template.sha256, m.winemac.originalSHA256, m.winemac.patchedUnsignedSHA256] + Array(m.originalGameDLLs.values) {
            XCTAssertEqual(hash.count, 64)
            XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
        for p in m.winemac.patches {
            XCTAssertEqual(p.expected.count, p.replacement.count)
            XCTAssertFalse(p.note.isEmpty)
        }
        XCTAssertEqual(m.engine.url.scheme, "https")
        XCTAssertEqual(m.steam.setupURL.host, "cdn.cloudflare.steamstatic.com")
    }
}

final class RedactionTests: XCTestCase {
    func testRemovesPersonalData() {
        let text = "/Users/alice/Library/x steam 76561198012345678 mail alice@example.com ip 192.168.1.20 token=abc123"
        let out = Redaction.redact(text, homeDirectory: "/Users/alice", userName: "alice")
        XCTAssertFalse(out.contains("alice"))
        XCTAssertFalse(out.contains("76561198012345678"))
        XCTAssertFalse(out.contains("192.168.1.20"))
        XCTAssertFalse(out.contains("abc123"))
        XCTAssertTrue(out.contains("~/Library/x"))
    }
}


final class PatchReportTests: XCTestCase {
    func testCountsAppliedAndSkipped() {
        let text = "0x004a4af4 skipped: math disabled\r\n0x004d1870 applied\r\n0x00572010 applied\r\n0x008ef125 skipped: signature mismatch or unreadable\r\n"
        let report = PatchReport.parse(text)
        XCTAssertEqual(report, PatchReport(applied: 2, skipped: 1, disabled: 1))
        XCTAssertFalse(report.isEmpty)
    }

    func testEmptyLogIsEmpty() {
        XCTAssertTrue(PatchReport.parse("").isEmpty)
        XCTAssertTrue(PatchReport.parse("garbage line").isEmpty)
    }
}

final class PrefixSafetyTests: XCTestCase {
    private func makePaths() -> (SteppePaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-prefix-safety-\(UUID().uuidString)")
        return (SteppePaths(root: root), root)
    }

    func testCreateRefusesToDeleteAnInstalledGame() async throws {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = paths.steamApps.appendingPathComponent("common/Cossacks 3")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: game.appendingPathComponent("cossacks.exe"))
        do {
            try await PrefixBuilder.create(runner: WineRunner(paths: paths), environment: [:])
            XCTFail("create must refuse")
        } catch PrefixError.refusingToDeleteGameData {
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.appendingPathComponent("cossacks.exe").path), "game files must survive")
    }

    func testEngineChangeIsAnUpdateNotARebuild() throws {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: paths.driveC.appendingPathComponent("windows"), withIntermediateDirectories: true)
        try Data().write(to: paths.prefixDir.appendingPathComponent("system.reg"))
        try ComponentMarker(name: "prefix", checksum: "old-engine", patchRevision: 0).write(paths.prefixMarker)
        XCTAssertTrue(PrefixBuilder.isHealthy(paths: paths), "an older engine must not make the prefix look broken")
        XCTAssertTrue(PrefixBuilder.needsUpdate(paths: paths))
        try ComponentMarker(name: "prefix", checksum: RuntimeManifest.current.engine.sha256, patchRevision: RuntimeManifest.current.patchRevision).write(paths.prefixMarker)
        XCTAssertFalse(PrefixBuilder.needsUpdate(paths: paths))
    }
}


final class GameFilesUpgradeTests: XCTestCase {
    func testNewerSteppeReplacesItsOwnOlderLibraries() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-upgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let v1 = base.appendingPathComponent("v1"), v2 = base.appendingPathComponent("v2"), game = base.appendingPathComponent("game")
        for dir in [v1, v2, game] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        var known: [String: String] = [:]
        for name in GameFiles.libraryNames {
            try Data("orig-\(name)".utf8).write(to: game.appendingPathComponent(name))
            try Data("v1-\(name)".utf8).write(to: v1.appendingPathComponent(name))
            try Data("v2-\(name)".utf8).write(to: v2.appendingPathComponent(name))
            known[name] = Hashing.sha256(of: Data("orig-\(name)".utf8))
        }
        _ = GameFiles.installSpeedLibraries(from: v1, into: game, knownOriginals: known)
        let upgrade = GameFiles.installSpeedLibraries(from: v2, into: game, knownOriginals: known)
        XCTAssertTrue(upgrade.allSatisfy { if case .installed = $0 { return true } else { return false } })
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("ogg.dll")), "v2-ogg.dll")
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("ogg.dll.steppe-orig")), "orig-ogg.dll", "the first backup stays the true original")

        // A file Steppe did not install (for example from a game update) is still left alone.
        try Data("game update".utf8).write(to: game.appendingPathComponent("vorbis.dll"))
        let blocked = GameFiles.installSpeedLibraries(from: v1, into: game, knownOriginals: known)
        XCTAssertTrue(blocked.contains(.skippedUnknownFile("vorbis.dll")))
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("vorbis.dll")), "game update")
    }
}


final class PrefixIsolationEdgeTests: XCTestCase {
    func testIsolateRepairsADriveCThatPointsOutsideThePrefix() throws {
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent("steppe-cdrive-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: prefix) }
        let dos = prefix.appendingPathComponent("dosdevices")
        try fm.createDirectory(at: dos, withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/users"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dos.appendingPathComponent("c:").path, withDestinationPath: "/")
        XCTAssertFalse(PrefixBuilder.escapesPrefix(prefix: prefix).isEmpty, "C: pointing at / must be reported")
        try PrefixBuilder.isolate(prefix: prefix)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dos.appendingPathComponent("c:").path), "../drive_c")
        XCTAssertTrue(PrefixBuilder.escapesPrefix(prefix: prefix).isEmpty)
    }
}

final class InstallLockTests: XCTestCase {
    func testOnlyOneHolderAtATime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: InstallLock? = InstallLock(root: root)
        XCTAssertNotNil(first)
        XCTAssertNil(InstallLock(root: root), "a second holder must be refused while the first is alive")
        first = nil
        XCTAssertNotNil(InstallLock(root: root), "the lock is free again once released")
    }
}
