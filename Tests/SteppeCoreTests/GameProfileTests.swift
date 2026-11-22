import XCTest
@testable import SteppeCore

final class GameProfileTests: XCTestCase {
    private func candidate() throws -> GameProfile {
        // Synthetic fixture, never advertised or installed as a supported Steam game.
        try GameProfile.validated(
            id: "fixture-game",
            displayName: "Fixture",
            steamAppID: 42,
            executableName: "fixture.exe",
            documentsSubpath: "Documents/Fixture",
            profilesSubpath: "Documents/Fixture/profiles"
        )
    }

    func testExistingInstallPathsRemainStable() {
        let paths = SteppePaths(root: URL(fileURLWithPath: "/tmp/steppe"))
        XCTAssertEqual(paths.prefixDir.path, "/tmp/steppe/prefixes/cossacks3")
        XCTAssertEqual(paths.profile.steamAppID, 333_420)
        XCTAssertEqual(paths.profile.executableName, "cossacks.exe")
        XCTAssertEqual(paths.profile.integration, .cossacks3)
        XCTAssertEqual(paths.profile.profilesSubpath, "Documents/cossacks/profiles")
    }

    func testProfilesIsolatePrefixesAndPreserveCandidateDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-gp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = SteppePaths(root: root, profile: try candidate())
        let cossacks = SteppePaths(root: root)
        XCTAssertNotEqual(paths.prefixDir, cossacks.prefixDir)

        let save = paths.driveC.appendingPathComponent("users/steppe/Documents/Fixture/profiles/save.dat")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("saved".utf8).write(to: save)

        XCTAssertEqual(paths.gameProfilesDir?.lastPathComponent, "profiles")
        XCTAssertEqual(paths.gameDocumentsDir?.lastPathComponent, "Fixture")

        do {
            try await PrefixBuilder.create(runner: WineRunner(paths: paths), environment: [:])
            XCTFail("Expected PrefixBuilder.create to refuse overwriting existing user saves")
        } catch let err as PrefixError {
            XCTAssertEqual(err, .refusingToDeleteGameData)
        }
        XCTAssertEqual(try Data(contentsOf: save), Data("saved".utf8))
    }

    func testSteamDetectionUsesCandidateIdentityAndExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-gp-steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = SteppePaths(root: root, profile: try candidate())
        let dir = paths.steamApps.appendingPathComponent("common/Fixture")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("\"StateFlags\" \"4\"\n\"installdir\" \"Fixture\"\n".utf8).write(to: paths.appManifestURL(appID: 42))

        let kit = SteamKit(paths: paths)
        XCTAssertFalse(kit.isGameInstalled)
        try Data().write(to: dir.appendingPathComponent("cossacks.exe"))
        XCTAssertFalse(kit.isGameInstalled, "Another game's executable must not satisfy this profile")
        try Data().write(to: dir.appendingPathComponent("fixture.exe"))
        XCTAssertTrue(kit.isGameInstalled)
        XCTAssertNil(SteamKit(paths: SteppePaths(root: root)).appManifest)
    }

    func testNewGameDoesNotInheritCossacksInjectionOrMathPatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-gp-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("libglfix.dylib"))

        var settings = AppSettings()
        settings.enableSpeedPatches = true
        settings.experimentalMathPatches = true
        settings.recordFrameTimes = true

        let paths = SteppePaths(root: root, profile: try candidate())
        let env = WineEnvironment(paths: paths, nativeDir: root).game(settings: settings)
        for key in ["DYLD_INSERT_LIBRARIES", "GLFIX_REMAP", "C3_VORBIS_CACHE", "STEPPE_PATCH_LOG", "STEPPE_MATH_PATCHES", "GLFIX_FRAMETIMES"] {
            XCTAssertNil(env[key], key)
        }

        let cossacksEnv = WineEnvironment(paths: SteppePaths(root: root), nativeDir: root).game(settings: settings)
        XCTAssertEqual(cossacksEnv["GLFIX_REMAP"], "2")
        XCTAssertEqual(cossacksEnv["C3_VORBIS_CACHE"], "1")
        XCTAssertEqual(cossacksEnv["STEPPE_MATH_PATCHES"], "1")
    }

    func testRejectsUnsafePathsAndInvalidIdentity() {
        for id in ["", "../escape", "a/b", "UPPER", "a\\b"] {
            XCTAssertThrowsError(
                try GameProfile.validated(id: id, displayName: "Fixture", steamAppID: 42, executableName: "x.exe")
            )
        }
        for path in ["../save", "/tmp/save", "C:\\save", "a/../b", "a//b", "a/", "a\0b"] {
            XCTAssertThrowsError(
                try GameProfile.validated(id: "fixture", displayName: "Fixture", steamAppID: 42, executableName: "x.exe", documentsSubpath: path)
            )
        }
        XCTAssertThrowsError(
            try GameProfile.validated(id: "fixture", displayName: "   ", steamAppID: 42, executableName: "x.exe")
        )
        XCTAssertThrowsError(
            try GameProfile.validated(id: "fixture", displayName: "Fixture", steamAppID: 0, executableName: "x.exe")
        )
        XCTAssertThrowsError(
            try GameProfile.validated(id: "fixture", displayName: "Fixture", steamAppID: 42, executableName: "bin/x.exe")
        )
        XCTAssertThrowsError(
            try GameProfile.validated(id: "fixture", displayName: "Fixture", steamAppID: 42, executableName: "x.bat")
        )
    }
}
