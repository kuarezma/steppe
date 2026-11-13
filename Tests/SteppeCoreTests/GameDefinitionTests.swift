import XCTest
@testable import SteppeCore

final class GameDefinitionTests: XCTestCase {
    private func candidate() throws -> GameDefinition {
        // Synthetic fixture, never advertised or installed as a supported Steam game.
        try GameDefinition(id: "fixture-game", displayName: "Fixture", steamAppID: 42,
                           executableName: "fixture.exe", documentsRelativePath: "Documents/Fixture",
                           profilesRelativePath: "Documents/Fixture/profiles")
    }

    func testExistingInstallPathsRemainStable() {
        let paths = SteppePaths(root: URL(fileURLWithPath: "/tmp/steppe"))
        XCTAssertEqual(paths.prefixDir.path, "/tmp/steppe/prefixes/cossacks3")
        XCTAssertEqual(paths.game.steamAppID, 333420)
        XCTAssertEqual(paths.game.executableName, "cossacks.exe")
        XCTAssertEqual(RuntimeManifest.current.steam.appID, paths.game.steamAppID)
    }

    func testDefinitionsIsolatePrefixesAndPreserveCandidateDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteppePaths(root: root, game: try candidate())
        let cossacks = SteppePaths(root: root)
        XCTAssertNotEqual(paths.prefixDir, cossacks.prefixDir)
        let save = paths.driveC.appendingPathComponent("users/steppe/Documents/Fixture/profiles/save.dat")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("saved".utf8).write(to: save)
        XCTAssertEqual(paths.gameProfilesDir?.lastPathComponent, "profiles")
        let backup = try XCTUnwrap(PrefixBuilder.clearForCreation(paths: paths))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("drive_c/users/steppe/Documents/Fixture/profiles/save.dat")), Data("saved".utf8))
    }

    func testSteamDetectionUsesCandidateIdentityAndExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SteppePaths(root: root, game: try candidate())
        let dir = paths.steamApps.appendingPathComponent("common/Fixture")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("\"StateFlags\" \"4\"\n\"installdir\" \"Fixture\"\n".utf8).write(to: paths.appManifestURL(appID: 42))
        let kit = SteamKit(paths: paths)
        XCTAssertFalse(kit.isGameInstalled)
        try Data().write(to: dir.appendingPathComponent("cossacks.exe"))
        XCTAssertFalse(kit.isGameInstalled, "Another game's executable must not satisfy this definition")
        try Data().write(to: dir.appendingPathComponent("fixture.exe"))
        XCTAssertTrue(kit.isGameInstalled)
        XCTAssertNil(SteamKit(paths: SteppePaths(root: root)).appManifest)
    }

    func testNewGameDoesNotInheritCossacksInjectionOrMathPatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("libglfix.dylib"))
        var settings = AppSettings()
        settings.experimentalMathPatches = true
        settings.recordFrameTimes = true
        let paths = SteppePaths(root: root, game: try candidate())
        let env = WineEnvironment(paths: paths, nativeDir: root).game(settings: settings)
        for key in ["DYLD_INSERT_LIBRARIES", "GLFIX_REMAP", "STEPPE_PATCH_LOG", "STEPPE_MATH_PATCHES", "GLFIX_FRAMETIMES"] {
            XCTAssertNil(env[key], key)
        }
        let existing = WineEnvironment(paths: SteppePaths(root: root), nativeDir: root).game(settings: settings)
        XCTAssertEqual(existing["GLFIX_REMAP"], "2")
        XCTAssertEqual(existing["STEPPE_MATH_PATCHES"], "1")
    }

    func testRejectsUnsafePathsAndInvalidIdentity() {
        for id in ["", "../escape", "a/b", "UPPER", "a\\b"] {
            XCTAssertThrowsError(try GameDefinition(id: id, displayName: "Fixture", steamAppID: 42, executableName: "x.exe"))
        }
        for path in ["../save", "/tmp/save", "C:\\save", "a/../b", "a//b", "a/", "a\0b"] {
            XCTAssertThrowsError(try GameDefinition(id: "fixture", displayName: "Fixture", steamAppID: 42,
                                                   executableName: "x.exe", documentsRelativePath: path))
        }
        XCTAssertThrowsError(try GameDefinition(id: "fixture", displayName: "Fixture", steamAppID: 0, executableName: "x.exe"))
        XCTAssertThrowsError(try GameDefinition(id: "fixture", displayName: "Fixture", steamAppID: 42, executableName: "bin/x.exe"))
    }
}
