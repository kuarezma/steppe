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


    private static let panelOriginal = """
          [*] = ;if ((GetViewerWidth)<1260) then
          [*] = ;dpiscale := GetViewerWidth/1260;
          [*] = ;var elmParent : Integer = _gui_CreateParent(elmname, 0, gc_halParentLeft, gc_valParentTop, 0, 0, round(GetViewerWidth/dpiscale), GetGUITextureHeight('resourcepanel.background'), True);
          [*] = ;_gui_AbsScaleByDPI(elmParent);
          [*] = ;_gui_SetAbsScale(elmParent, dpiscale);
          [*] = ;SetGUIElementVisible(elmParent, (gInterface.gamemode<>gc_gamemode_mainmenu));
          [*] = ;var xoff : Integer;
          [*] = ;if ((GetViewerWidth/basedpiscale)<cminwidth) then
          [*] = ;xoff := round(-45*dpiscale)
          [*] = ;else
          [*] = ;if ((GetViewerWidth/basedpiscale)<1440) then
          [*] = ;xoff := -100;
          [*] = ;var elm : Integer = _gui_CreateImageActive('resbackground', elmParent, 'resourcepanel.background', gc_halParentMiddle, gc_valParentTop, xoff, cResourceOffY, 0, 0, 0, '', '', True);
    """

    private static let resourceTextsOriginal = """
          [*] = ;   _gui_CreateTextShadowed('resource'+IntToStr(ind), elmParent, text, gc_halParentMiddle, gc_valParentTop, x+xoff, cResourceOffY-4, cResourceSizeX, GetGUIElementHeight(elmParent), gc_halLeft, gc_valMiddle, gc_font_serif_13, color, 1, 1, shcolor, True);
          [*] = ;
          [*] = ;   if (dpiscale=2) then
          [*] = ;   _gui_CreateImageActive('resourcehint'+IntToStr(ind), elmParent, gc_gui_material_blank, gc_halParentMiddle, gc_valParentMiddle, x-160+xoff, cResourceOffY-10, cResourceSizeX-10, GetGUIElementHeight(elmParent), 0, '', hint, True)
          [*] = ;   else
          [*] = ;   _gui_CreateImageActive('resourcehint'+IntToStr(ind), elmParent, gc_gui_material_blank, gc_halParentMiddle, gc_valParentMiddle, x-60+xoff, cResourceOffY-10, cResourceSizeX-10, GetGUIElementHeight(elmParent), 0, '', hint, True);
    """

    private static let populationCreateOriginal = """
          [*] = ;var elmPopulationHnd : Integer = _gui_CreateImageActive('population', elmParent, gc_gui_material_blank, gc_halParentLeft, gc_valParentTop, 0, 5, 142, GetGUIElementHeight(elmParent), 0, '', cTextHintFarm, True);
    """

    private static let populationAndIdleOriginal = """
          [*] = ;_gui_CreateTextShadowed('_txt_population', elmPopulationHnd, text, gc_halParentLeft, gc_valParentTop, cPopulationOffsetX, 0, 0, GetGUIElementHeight(elmParent), gc_halLeft, gc_valMiddle, gc_font_sans_12, color, 1, 1, shcolor, True);
          [*] = ;
          [*] = ;var bObjectivesExists : Boolean;
          [*] = ;if (gScenario.bactive) then
          [*] = ;begin
          [*] = ;   var i : Integer;
          [*] = ;   for i:=0 to gc_scenario_maxobjectives-1 do
          [*] = ;   if (gScenario.objectives[i].bvisible) then
          [*] = ;   begin
          [*] = ;      bObjectivesExists := True;
          [*] = ;      break;
          [*] = ;   end;
          [*] = ;end;
          [*] = ;
          [*] = ;var posY : Integer;
          [*] = ;if (bObjectivesExists) then
          [*] = ;posY := 50;
    """

    private static let objectivesOriginal = """
          [*] = ;var elmObjectives : Integer = _gui_CreateParent('objs', elmParent, gc_halParentLeft, gc_valParentTop, 54+5+cpadding-8, 66+cpadding-8, 0, 0, True);
          [*] = ;if (bPaper) then
          [*] = ;elmObjectivesBackground := _gui_CreateParent('bcg', elmObjectives, gc_halParentLeft, gc_valParentTop, 0, 0, 0, 0, True);
          [*] = ;//SetGUIElementUserBlend(elmObjectives, 1);
          [*] = ;if (gScenario.bactive) then
          [*] = ;begin
          [*] = ;   var listid : TIntegerList;
          [*] = ;   var listgametime : TIntegerList;
          [*] = ;   var material : String;
          [*] = ;   if (not bObjectivesExists) then
          [*] = ;   begin
          [*] = ;      material := gc_hud_icons_control+'showobjectives';
          [*] = ;      hint := cTextShowObjectivesDisabled;
          [*] = ;   end
          [*] = ;   else
          [*] = ;   if (not gInterface.bhideobjectives) then
          [*] = ;   begin
          [*] = ;      material := gc_hud_icons_control+'hideobjectives';
          [*] = ;      hint := cTextHideObjectives;
          [*] = ;   end
          [*] = ;   else
          [*] = ;   begin
          [*] = ;      material := gc_hud_icons_control+'showobjectives';
          [*] = ;      hint := cTextShowObjectives;
          [*] = ;   end;
          [*] = ;   var elmSwitchShowObjectivesHnd : Integer = _gui_CreateImage('_img_switchobjectives', elmParent, material, gc_halParentLeft, gc_valParentTop, 3, 64{+50+50}, 0, 0, 0, True);
    """

    private let panelPath = "data/gui/menu.inc/showresourcepanel.inc"

    private func writeHUD(in game: URL, newline: String = "\n") throws -> Data {
        // Non-ASCII Latin-1 bytes and surrounding content must survive patching unchanged.
        let body = [
            Self.panelOriginal,
            Self.resourceTextsOriginal,
            Self.populationCreateOriginal,
            Self.populationAndIdleOriginal,
            Self.objectivesOriginal,
        ].joined(separator: "\n// section\n")
        let target = game.appendingPathComponent(panelPath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = ("// café\n" + body + "\n// fin\n").replacingOccurrences(of: "\n", with: newline)
        let data = try XCTUnwrap(text.data(using: .isoLatin1))
        try data.write(to: target)
        return data
    }

    func testNotchHUDLowersResourceBarBelowNotchAndIsIdempotent() throws {
        for newline in ["\n", "\r\n"] {
            let (_, game, cleanup) = try makeDirs()
            defer { cleanup() }
            let original = try writeHUD(in: game, newline: newline)
            XCTAssertEqual(GameFiles.applyNotchHUD(in: game, enabled: true), [.installed(panelPath)])
            let target = game.appendingPathComponent(panelPath)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathExtension("steppe-orig")), original)
            let patched = try Data(contentsOf: target)
            XCTAssertNotEqual(patched, original)
            let text = try XCTUnwrap(String(data: patched, encoding: .isoLatin1))
            XCTAssertTrue(text.hasPrefix("// café" + newline))
            XCTAssertTrue(text.hasSuffix("// fin" + newline))
            if newline == "\r\n" {
                XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
            } else {
                XCTAssertFalse(text.contains("\r"))
            }
            for fragment in [
                "var bNotchBar : Boolean = (((GetViewerWidth/GetViewerHeight)>1.50) and ((GetViewerWidth/GetViewerHeight)<1.58) and (GetDisplayMode<>'dmWindow'));",
                "notchDropY := Max(46, round(GetViewerHeight*0.042/dpiscale));",
                "resPanelBaseH+notchDropY",
                "cResourceOffY+notchDropY",
                "cResourceOffY-4+notchDropY, cResourceSizeX, resPanelBaseH",
                "cResourceOffY-10+notchDropY, cResourceSizeX-10, resPanelBaseH",
                "var posY : Integer = notchDropY;",
                "66+cpadding-8+notchDropY",
                "64+notchDropY{+50+50}",
            ] { XCTAssertTrue(text.contains(fragment), fragment) }
            XCTAssertEqual(GameFiles.applyNotchHUD(in: game, enabled: true), [.alreadyCurrent(panelPath)])

            // Reapply after Steam updates the target file: refreshed backup must capture the new original.
            let updatedOriginal = try XCTUnwrap((String(data: original, encoding: .isoLatin1)! + "// steam-update" + newline).data(using: .isoLatin1))
            try updatedOriginal.write(to: target)
            XCTAssertEqual(GameFiles.applyNotchHUD(in: game, enabled: true), [.installed(panelPath)])
            XCTAssertEqual(try Data(contentsOf: target.appendingPathExtension("steppe-orig")), updatedOriginal)
        }
    }

    func testNotchHUDRestoresOriginalBytesAndRemovesBackups() throws {
        for useRestoreOriginals in [false, true] {
            let (_, game, cleanup) = try makeDirs()
            defer { cleanup() }
            let original = try writeHUD(in: game, newline: "\r\n")
            XCTAssertEqual(GameFiles.applyNotchHUD(in: game, enabled: true), [.installed(panelPath)])
            if useRestoreOriginals {
                XCTAssertEqual(GameFiles.restoreOriginals(in: game), 1)
                XCTAssertEqual(GameFiles.restoreOriginals(in: game), 0)
            } else {
                XCTAssertEqual(GameFiles.applyNotchHUD(in: game, enabled: false), [.installed(panelPath)])
            }
            let target = game.appendingPathComponent(panelPath)
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathExtension("steppe-orig").path))
            XCTAssertEqual(GameFiles.applyNotchHUD(in: game, enabled: false), [.alreadyCurrent(panelPath)])
        }
    }

    func testNotchHUDDoesNotOverwriteSteamUpdatedFileWhenDisabledOrRestored() throws {
        for useRestoreOriginals in [false, true] {
            let (_, game, cleanup) = try makeDirs()
            defer { cleanup() }
            let original = try writeHUD(in: game)
            XCTAssertEqual(GameFiles.applyNotchHUD(in: game, enabled: true), [.installed(panelPath)])
            let target = game.appendingPathComponent(panelPath)
            let steamUpdated = original + Data("// steam-updated\n".utf8)
            try steamUpdated.write(to: target)
            if useRestoreOriginals {
                XCTAssertEqual(GameFiles.restoreOriginals(in: game), 0)
            } else {
                _ = GameFiles.applyNotchHUD(in: game, enabled: false)
            }
            XCTAssertEqual(try Data(contentsOf: target), steamUpdated)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathExtension("steppe-orig").path))
        }
    }

    func testNotchHUDRejectsUnknownBlocksWithoutTouchingFile() throws {
        for block in ["GetViewerWidth/1260", "cResourceOffY-4", "cPopulationOffsetX", "66+cpadding-8"] {
            let (_, game, cleanup) = try makeDirs()
            defer { cleanup() }
            let original = try writeHUD(in: game)
            let target = game.appendingPathComponent(panelPath)
            let text = try XCTUnwrap(String(data: original, encoding: .isoLatin1))
            let modified = try XCTUnwrap(text.replacingOccurrences(of: block, with: "unknown").data(using: .isoLatin1))
            try modified.write(to: target)
            XCTAssertEqual(GameFiles.applyNotchHUD(in: game, enabled: true), [.skippedUnknownFile(panelPath)])
            XCTAssertEqual(try Data(contentsOf: target), modified)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathExtension("steppe-orig").path))
        }
    }

    func testNotchHUDRestoresLegacyHudMatBackupIfPresent() throws {
        let (_, game, cleanup) = try makeDirs()
        defer { cleanup() }
        _ = try writeHUD(in: game)
        let hudMat = game.appendingPathComponent("data/hud/hud.mat")
        try FileManager.default.createDirectory(at: hudMat.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hudOriginal = Data("original-hud-mat".utf8)
        let hudPatched = Data("legacy-split-hud-mat".utf8)
        try hudPatched.write(to: hudMat)
        try hudOriginal.write(to: hudMat.appendingPathExtension("steppe-orig"))
        let record = ["data/hud/hud.mat": Hashing.sha256(of: hudPatched)]
        try JSONEncoder().encode(record).write(to: game.appendingPathComponent(GameFiles.installedRecordName))

        XCTAssertEqual(GameFiles.applyNotchHUD(in: game, enabled: true), [.installed(panelPath)])
        XCTAssertEqual(try Data(contentsOf: hudMat), hudOriginal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hudMat.appendingPathExtension("steppe-orig").path))
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

    func testReplaceFileRollbackPreservesTargetOnFailure() throws {
        let (src, game, cleanup) = try makeDirs()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.path)
            cleanup()
        }
        let target = game.appendingPathComponent("ogg.dll")
        try Data("original-bytes".utf8).write(to: target)

        // Case 1: missing source is rejected before moving target.
        let missingSource = src.appendingPathComponent("missing.dll")
        XCTAssertThrowsError(try GameFiles.replaceFile(at: target, with: missingSource))
        XCTAssertEqual(try String(contentsOf: target), "original-bytes", "target must survive missing-source failure")

        // Case 2: source exists, but src directory is read-only (0o555), so moving source out of src fails
        // with EACCES after target is moved to rollback, exercising the rollback restoration path.
        let lockedSource = src.appendingPathComponent("locked.dll")
        try Data("new-bytes".utf8).write(to: lockedSource)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: src.path)
        XCTAssertThrowsError(try GameFiles.replaceFile(at: target, with: lockedSource))
        XCTAssertEqual(try String(contentsOf: target), "original-bytes", "rollback must restore target after move failure")
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

final class WindowsUserDirTests: XCTestCase {
    private func makePaths(users: [String]) throws -> (SteppePaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-users-\(UUID().uuidString)")
        let paths = SteppePaths(root: root)
        for user in users {
            try FileManager.default.createDirectory(
                at: paths.driveC.appendingPathComponent("users/\(user)"), withIntermediateDirectories: true)
        }
        return (paths, root)
    }

    func testPrefersSteppeOverPseudoUsers() throws {
        let (paths, root) = try makePaths(users: ["All Users", "Default", "Public", "steppe"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(paths.windowsUserDir?.lastPathComponent, "steppe")
    }

    func testReturnsNilWhenOnlyPseudoUsersExist() throws {
        let (paths, root) = try makePaths(users: ["Public", "Default"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(paths.windowsUserDir)
    }
}

final class MicrophoneAndEntitlementsTests: XCTestCase {
    func testAudioEntitlementsDoNotResignUnchangedPlugin() async throws {
        let fm = FileManager.default
        let engineRoot = fm.temporaryDirectory.appendingPathComponent("steppe-engine-so-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: engineRoot) }
        let binDir = engineRoot.appendingPathComponent("bin")
        let soDir = engineRoot.appendingPathComponent("lib/wine/x86_64-unix")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: soDir, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binDir.appendingPathComponent("wine"))
        let plugin = soDir.appendingPathComponent("winecoreaudio.so")
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: plugin)

        await WinePatcher.ensureAudioEntitlements(engineRoot: engineRoot)
        let first = try fm.attributesOfItem(atPath: plugin.path)
        await WinePatcher.ensureAudioEntitlements(engineRoot: engineRoot)
        let second = try fm.attributesOfItem(atPath: plugin.path)

        XCTAssertEqual(first[.modificationDate] as? Date, second[.modificationDate] as? Date)
        XCTAssertEqual(first[.systemFileNumber] as? UInt64, second[.systemFileNumber] as? UInt64)
    }

    func testMicrophonePermissionStatusAndLabels() {
        let status = MicrophonePermission.status()
        XCTAssertFalse(status.localizedLabel.isEmpty)
        for s in [MicrophoneStatus.authorized, .denied, .restricted, .notDetermined] {
            XCTAssertFalse(s.localizedLabel.isEmpty)
        }
    }

    func testWineAudioEntitlementsSigning() async throws {
        let fm = FileManager.default
        let engineRoot = fm.temporaryDirectory.appendingPathComponent("steppe-engine-ent-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: engineRoot) }
        let binDir = engineRoot.appendingPathComponent("bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let dummyWine = binDir.appendingPathComponent("wine")
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: dummyWine)

        await WinePatcher.ensureAudioEntitlements(engineRoot: engineRoot)

        let inspect = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "--entitlements", "-", dummyWine.path],
            timeout: 15
        )
        let combined = inspect.stdout + inspect.stderr
        XCTAssertTrue(combined.contains("com.apple.security.device.audio-input"), "wine binary must carry audio-input entitlement")
    }
}
