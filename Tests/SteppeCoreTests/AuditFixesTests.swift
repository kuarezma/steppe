import Darwin
import Foundation
import XCTest
@testable import SteppeCore

final class AuditFixesTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("steppe-audit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "steppe.audit.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - GameProfile, Paths, LaunchOutcome

    func testGameProfileParameterizesPathsAndLaunchOutcome() {
        let customProfile = GameProfile(
            id: "testgame",
            displayName: "Test Strategy",
            prefixDirectoryName: "testgame_prefix",
            executableName: "testgame.exe",
            steamAppID: 999_001,
            documentsSubpath: "Documents/TestStrategy",
            crashSignatures: ["deadbeef_fault"],
            minimumFreeBytes: 1_000_000
        )
        let paths = SteppePaths(root: root, profile: customProfile)
        XCTAssertEqual(paths.prefixDir, root.appendingPathComponent("prefixes/testgame_prefix", isDirectory: true))
        XCTAssertEqual(paths.appManifestURL(appID: customProfile.steamAppID).lastPathComponent, "appmanifest_999001.acf")
        XCTAssertEqual(paths.rootMarker, root.appendingPathComponent(".steppe-root.json"))

        let res = Resolution(width: 1920, height: 1080)
        let outcome = LaunchOutcome.classify(duration: 12, logTail: "fatal: deadbeef_fault at 0x10", resolution: res, profile: customProfile)
        XCTAssertEqual(outcome, .crashSignature(res))
        let note = outcome.userNote(for: customProfile)
        XCTAssertTrue(note?.contains("Test Strategy") == true)
        XCTAssertTrue(note?.contains("1920") == true)
    }

    // MARK: - AppSettings schema v2 migration & clamping

    func testAppSettingsMigratesV1AndClampsOutOfRangeResolution() throws {
        let v1JSON = """
        {
          "preset": "quality",
          "customResolution": { "width": 100, "height": 99999 },
          "useCustomResolution": true
        }
        """
        let file = root.appendingPathComponent("settings.json")
        try Data(v1JSON.utf8).write(to: file)

        let loaded = AppSettings.load(from: file)
        XCTAssertEqual(loaded.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(loaded.preset, .quality)
        XCTAssertEqual(loaded.customResolution, Resolution(width: AppSettings.widthRange.lowerBound, height: AppSettings.heightRange.upperBound))
        XCTAssertFalse(loaded.enableMicrophone)
        XCTAssertTrue(loaded.enableSpeedPatches)
        XCTAssertTrue(loaded.enableNotchHUD)
        XCTAssertTrue(loaded.multithreadedEngine)
    }

    // MARK: - Disk status & InstallLock

    func testDiskStatusDetectsUnmountedExternalVolume() {
        let missingVol = URL(fileURLWithPath: "/Volumes/SteppeMissingDrive-\(UUID().uuidString)/Steppe", isDirectory: true)
        if case .externalVolumeUnmounted(let name) = SystemInfo.diskStatus(at: missingVol) {
            XCTAssertTrue(name.hasPrefix("SteppeMissingDrive-"))
        } else {
            XCTFail("Expected .externalVolumeUnmounted for nonexistent volume")
        }

        if case .available(let bytes) = SystemInfo.diskStatus(at: root) {
            XCTAssertGreaterThan(bytes, 0)
        } else {
            XCTFail("Expected .available for temp dir")
        }
    }

    func testInstallLockAcquireReturnsAlreadyHeldThenSucceedsAfterRelease() {
        var holder: InstallLock?
        if case .success(let lock) = InstallLock.acquire(root: root) {
            holder = lock
        } else {
            return XCTFail("Initial lock failed")
        }
        if case .failure(let err) = InstallLock.acquire(root: root) {
            XCTAssertEqual(err, .alreadyHeld)
        } else {
            XCTFail("Second concurrent lock should fail with .alreadyHeld")
        }
        holder = nil
        _ = holder
        if case .success = InstallLock.acquire(root: root) {
            // Released cleanly on deinit.
        } else {
            XCTFail("Expected re-acquire to succeed after holder deinit")
        }

        // Directory creation failure maps to .directoryError instead of misinterpreting Cocoa code as errno.
        let fileBlocker = root.appendingPathComponent("blocker")
        try? Data("x".utf8).write(to: fileBlocker)
        if case .failure(let dirErr) = InstallLock.acquire(root: fileBlocker.appendingPathComponent("child")) {
            if case .directoryError(let desc) = dirErr {
                XCTAssertFalse(desc.isEmpty)
            } else {
                XCTFail("Expected .directoryError, got \(dirErr)")
            }
        } else {
            XCTFail("Expected .directoryError when parent path is a file")
        }
    }

    // MARK: - Redaction & ProcessFailure

    func testRedactionSanitizesPathsIPsAndWordBoundedUserName() {
        let input = "Home /Users/alice/docs External /Volumes/GameDisk/Data Spaced /Volumes/My SSD/Steam/logs Apo /Volumes/Ugur's Disk/Steppe RootOnly /Volumes/My SSD\nIP 192.168.10.50 dot 192.168.1.5. ver 1.2.3.400 ver5 1.2.3.4.5 user bob bobby bob_1 76561198000000001"
        let clean = Redaction.redact(input, homeDirectory: "/Users/other", userName: "bob")
        XCTAssertFalse(clean.contains("/Users/alice"))
        XCTAssertTrue(clean.contains("/Users/<user>/docs"))
        XCTAssertFalse(clean.contains("/Volumes/GameDisk"))
        XCTAssertTrue(clean.contains("/Volumes/<volume>/Data"))
        XCTAssertFalse(clean.contains("My SSD"))
        XCTAssertFalse(clean.contains("Ugur's Disk"))
        XCTAssertTrue(clean.contains("/Volumes/<volume>/Steam/logs"))
        XCTAssertTrue(clean.contains("Apo /Volumes/<volume>/Steppe"))
        XCTAssertTrue(clean.contains("RootOnly /Volumes/<volume>"))

        let extPaths = SteppePaths(root: URL(fileURLWithPath: "/Volumes/Ugur's SSD/Steppe", isDirectory: true))
        let snapshot = DiagnosticsSnapshot(
            system: SystemInfo.detect(),
            display: nil,
            displayModes: nil,
            resolution: Resolution(width: 1920, height: 1080),
            settings: AppSettings(),
            microphoneStatus: .notDetermined,
            stageSummary: [],
            phase: String(describing: AppPhase.failed(SetupError.externalDriveNotConnected("Ugur's SSD").localizedDescription)),
            freeBytes: 0,
            gameManifest: nil,
            paths: extPaths,
            leaks: []
        )
        let diag = Diagnostics.sanitizedReport(for: snapshot)
        XCTAssertFalse(diag.contains("Ugur's SSD"))
        XCTAssertTrue(clean.contains("IP <ip>"))
        XCTAssertTrue(clean.contains("dot <ip>."))
        // Out-of-range version quartet 1.2.3.400 and 5-part 1.2.3.4.5 should not match strict IPv4.
        XCTAssertTrue(clean.contains("1.2.3.400"))
        XCTAssertTrue(clean.contains("1.2.3.4.5"))
        XCTAssertTrue(clean.contains("user <user> bobby bob_1"))
        XCTAssertTrue(clean.contains("<steamid>"))

        let failure = ProcessFailure.nonZeroExit("wine", CommandResult(exitCode: 1, stdout: "", stderr: "error in /Users/alice/secret"))
        let desc = failure.errorDescription ?? ""
        XCTAssertFalse(desc.contains("/Users/alice"))
        XCTAssertTrue(desc.contains("/Users/<user>/secret"))
    }

    // MARK: - WineEnvironment

    func testWineEnvironmentAllowlistAndSpeedPatchGating() throws {
        let nativeDir = root.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDir, withIntermediateDirectories: true)
        let glfix = nativeDir.appendingPathComponent("libglfix.dylib")
        try Data().write(to: glfix)

        let paths = SteppePaths(root: root)
        let envBuilder = WineEnvironment(paths: paths, nativeDir: nativeDir)

        var safeSettings = AppSettings()
        safeSettings.enableSpeedPatches = false
        let safeEnv = envBuilder.game(settings: safeSettings)
        XCTAssertEqual(safeEnv["WINEDEBUG"], "-all,err+seh")
        XCTAssertEqual(safeEnv["C3_VORBIS_CACHE"], "0")
        XCTAssertNil(safeEnv["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(safeEnv["GLFIX_REMAP"])
        XCTAssertNil(safeEnv["STEPPE_PATCH_LOG"])

        var fastSettings = AppSettings()
        fastSettings.enableSpeedPatches = true
        let fastEnv = envBuilder.game(settings: fastSettings)
        XCTAssertEqual(fastEnv["C3_VORBIS_CACHE"], "1")
        XCTAssertEqual(fastEnv["DYLD_INSERT_LIBRARIES"], glfix.path)
        XCTAssertEqual(fastEnv["GLFIX_REMAP"], "2")

        // Ensure arbitrary host env vars are not leaked unless allowlisted.
        setenv("STEPPE_TEST_SECRET_TOKEN", "topsecret", 1)
        defer { unsetenv("STEPPE_TEST_SECRET_TOKEN") }
        XCTAssertNil(envBuilder.setup()["STEPPE_TEST_SECRET_TOKEN"])
    }

    // MARK: - Downloader ETag / If-Range & 416 recovery

    func testDownloaderUsesIfRangeAndRecoversFrom416() async throws {
        final class ETagResumeServer: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var payload = Data((0..<80_000).map { UInt8($0 % 239) })
            nonisolated(unsafe) static var callCount = 0
            nonisolated(unsafe) static var seenIfRanges: [String?] = []
            nonisolated(unsafe) static var simulate416OnSecondCall = false

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func stopLoading() {}

            override func startLoading() {
                Self.callCount += 1
                Self.seenIfRanges.append(request.value(forHTTPHeaderField: "If-Range"))
                let url = request.url!

                if Self.callCount == 1 {
                    let headers = ["Content-Length": "\(Self.payload.count)", "ETag": "\"v1-etag\""]
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(Self.payload.prefix(16_384)))
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                    }
                    return
                }

                if Self.simulate416OnSecondCall && Self.callCount == 2 {
                    let resp = HTTPURLResponse(url: url, statusCode: 416, httpVersion: nil, headerFields: [:])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }

                var start = 0
                var status = 200
                if let r = request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes="),
                   let offset = Int(r.dropFirst(6).split(separator: "-").first ?? "") {
                    start = offset
                    status = 206
                }
                let body = Self.payload.subdata(in: start..<Self.payload.count)
                let headers = ["Content-Length": "\(body.count)", "ETag": "\"v1-etag\""]
                let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        ETagResumeServer.callCount = 0
        ETagResumeServer.seenIfRanges = []
        ETagResumeServer.simulate416OnSecondCall = true

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ETagResumeServer.self]
        let dest = root.appendingPathComponent("dl/artifact.tar.gz")
        let sha = Hashing.sha256(of: ETagResumeServer.payload)
        try await Downloader.download(
            url: URL(string: "https://example.invalid/artifact.tar.gz")!,
            to: dest,
            expectedSHA256: sha,
            expectedSize: Int64(ETagResumeServer.payload.count),
            maxAttempts: 4,
            configuration: cfg,
            retryDelayUnit: 1_000_000
        ) { _ in }

        XCTAssertEqual(try Data(contentsOf: dest), ETagResumeServer.payload)
        XCTAssertEqual(ETagResumeServer.seenIfRanges.count, 3)
        XCTAssertEqual(ETagResumeServer.seenIfRanges[1], "\"v1-etag\"")
        XCTAssertNil(ETagResumeServer.seenIfRanges[2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathExtension("part.meta").path))
    }

    // MARK: - SteamKit

    func testSteamACFUpdatingFlagAndPEVerification() throws {
        let acf = """
        "AppState"
        {
            "appid" "333420"
            "StateFlags" "1030"
            "installdir" "Cossacks 3"
        }
        """
        let info = try XCTUnwrap(SteamACF.parse(acf))
        XCTAssertTrue(info.isFullyInstalled)
        XCTAssertTrue(info.isUpdating)

        let exe = root.appendingPathComponent("valid_setup.exe")
        var bytes = Data(count: 600_000)
        bytes[0] = 0x4D; bytes[1] = 0x5A // MZ
        bytes[60] = 0x80; bytes[61] = 0x00; bytes[62] = 0x00; bytes[63] = 0x00
        bytes[0x80] = 0x50; bytes[0x81] = 0x45; bytes[0x82] = 0x00; bytes[0x83] = 0x00 // PE\0\0
        try bytes.write(to: exe)
        XCTAssertNoThrow(try SteamKit.verifyPEExecutable(at: exe))

        let badExe = root.appendingPathComponent("html_error.exe")
        try Data(repeating: 0x3C, count: 600_000).write(to: badExe) // '<'
        XCTAssertThrowsError(try SteamKit.verifyPEExecutable(at: badExe))
    }

    // MARK: - GameBootstrap & ProfileTuner multithreaded flag

    func testProfileConfigMultithreadedSettingAndRoundTrip() throws {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        _ = try GameBootstrap.seed(
            documentsGameDir: docs,
            profileName: "Player",
            locale: "en",
            resolution: Resolution(width: 1600, height: 1000),
            multithreaded: false
        )
        let cfgURL = docs.appendingPathComponent("profiles/Player/profile.cfg")
        let initial = try String(contentsOf: cfgURL, encoding: .utf8)
        XCTAssertEqual(ProfileConfig.multithreaded(in: initial), false)

        try ProfileTuner.apply(resolution: Resolution(width: 1920, height: 1200), multithreaded: true, profilesDir: docs.appendingPathComponent("profiles"))
        let updated = try String(contentsOf: cfgURL, encoding: .utf8)
        XCTAssertEqual(ProfileConfig.screenResolution(in: updated), Resolution(width: 1920, height: 1200))
        XCTAssertEqual(ProfileConfig.multithreaded(in: updated), true)
    }

    // MARK: - GameFiles restoreSpeedLibraries vs restoreOriginals

    func testGameFilesRestoreSpeedLibrariesLeavesHUDPatched() throws {
        let gameDir = root.appendingPathComponent("game", isDirectory: true)
        let nativeDir = root.appendingPathComponent("native", isDirectory: true)
        let hudMat = gameDir.appendingPathComponent(GameFiles.hudMatRelativePath)
        let resPanel = gameDir.appendingPathComponent(GameFiles.resourcePanelRelativePath)
        try FileManager.default.createDirectory(at: hudMat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resPanel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nativeDir, withIntermediateDirectories: true)

        let origOgg = Data("orig-ogg".utf8)
        let origVorbis = Data("orig-vorbis".utf8)
        let origVorbisfile = Data("orig-vorbisfile".utf8)
        try origOgg.write(to: gameDir.appendingPathComponent("ogg.dll"))
        try origVorbis.write(to: gameDir.appendingPathComponent("vorbis.dll"))
        try origVorbisfile.write(to: gameDir.appendingPathComponent("vorbisfile.dll"))
        try Data("fast-ogg".utf8).write(to: nativeDir.appendingPathComponent("ogg.dll"))
        try Data("fast-vorbis".utf8).write(to: nativeDir.appendingPathComponent("vorbis.dll"))
        try Data("fast-vf".utf8).write(to: nativeDir.appendingPathComponent("vorbisfile.dll"))

        let hudMatText = #"""
        section.begin {refurl=.\data\hud\ref\reflibmat.mat}
           Material.Name = resourcepanel.background
           Material.LibTextureName = tex03
           Material.TextureCoord.ImageH = 512
           Material.TextureCoord.CoordX = 386
           Material.TextureCoord.CoordY = 183
           Material.TextureCoord.CoordW = 1159
           Material.TextureCoord.CoordH = 58
        section.end
        """#
        let resPanelText = [
            """
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
            """,
            """
                  [*] = ;   const cSideOffsetX = -10;
                  [*] = ;   if (i<4) then
                  [*] = ;   x := x+(cSideOffsetX div 2)
                  [*] = ;   else
                  [*] = ;   x := x+cSideOffsetX+4;
            """,
            """
                  [*] = ;var elmPopulationHnd : Integer = _gui_CreateImageActive('population', elmParent, gc_gui_material_blank, gc_halParentLeft, gc_valParentTop, 0, 5, 142, GetGUIElementHeight(elmParent), 0, '', cTextHintFarm, True);
            """,
            """
                  [*] = ;var posY : Integer;
                  [*] = ;if (bObjectivesExists) then
                  [*] = ;posY := 50;
            """,
            """
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
            """,
        ].joined(separator: "\n")
        try Data(hudMatText.utf8).write(to: hudMat)
        try Data(resPanelText.utf8).write(to: resPanel)

        _ = GameFiles.installSpeedLibraries(
            from: nativeDir,
            into: gameDir,
            knownOriginals: [
                "ogg.dll": Hashing.sha256(of: origOgg),
                "vorbis.dll": Hashing.sha256(of: origVorbis),
                "vorbisfile.dll": Hashing.sha256(of: origVorbisfile),
            ]
        )
        let hudStatuses = GameFiles.applyNotchHUD(in: gameDir, enabled: true)
        XCTAssertEqual(hudStatuses, [
            .installed(GameFiles.hudMatRelativePath),
            .installed(GameFiles.resourcePanelRelativePath),
        ])

        let restoredLibs = GameFiles.restoreSpeedLibraries(in: gameDir)
        XCTAssertEqual(restoredLibs, 3)
        XCTAssertEqual(try Data(contentsOf: gameDir.appendingPathComponent("ogg.dll")), origOgg)
        // HUD backups and patches should still exist because restoreSpeedLibraries does not undo HUD patches.
        XCTAssertTrue(FileManager.default.fileExists(atPath: hudMat.appendingPathExtension("steppe-orig").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resPanel.appendingPathExtension("steppe-orig").path))

        let restoredHUD = GameFiles.restoreOriginals(in: gameDir)
        XCTAssertEqual(restoredHUD, 2)
    }

    // MARK: - SteppeController & SteppeRuntime mock lifecycle

    @MainActor
    func testControllerUninstallSelectiveCancelSuppressionRepairAndDiskStatus() async throws {
        struct MockRuntime: SteppeRuntime {
            var disk: SystemInfo.DiskStatus
            var rosetta = false
            func primaryDisplay() -> DisplayInfo {
                DisplayInfo(size: Resolution(width: 2560, height: 1600), scale: 2.0, maxRefreshRate: 60, name: "MockDisplay", hasNotch: false)
            }
            func diskStatus(at root: URL) async -> SystemInfo.DiskStatus { disk }
            func acquireLock(root: URL) -> Result<InstallLock, LockFailure> { InstallLock.acquire(root: root) }
            func isRosettaInstalled() async -> Bool { rosetta }
            func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? { nil }
            func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck { .notRunning }
            func isClientRunning(inEngine bundle: URL) async -> Bool { false }
            func isAnyProcessRunning(inEngine bundle: URL) async -> Bool { false }
            func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {}
            func killAllWine(paths: SteppePaths, environment: [String: String]) async {}
            func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {}
            func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {}
            func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {}
            func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? { nil }
            func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {}
            func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {}
            func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool { false }
            func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func isolatePrefix(_ prefix: URL) throws {}
            func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func ensureAudioEntitlements(engineRoot: URL) async {}
            func microphoneStatus() -> MicrophoneStatus { .notDetermined }
            @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
            @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
        }

        // 1) Disconnected external volume status surfaces accurately via refresh.
        let unmountedCtrl = SteppeController(
            nativeDir: nil,
            defaults: defaults,
            rootOverride: root,
            runtime: MockRuntime(disk: .externalVolumeUnmounted("MySSD")),
            pollIntervalNanoseconds: 20_000_000,
            configureGlobalLogger: false
        )
        await unmountedCtrl.refresh(allowAutoSetup: false)
        XCTAssertEqual(unmountedCtrl.diskStatus, .externalVolumeUnmounted("MySSD"))
        XCTAssertEqual(unmountedCtrl.freeBytes, 0)
        unmountedCtrl.startSetup()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(unmountedCtrl.phase, .failed(SetupError.externalDriveNotConnected("MySSD").localizedDescription))

        // 2) Setup wait -> cancelSetup sets autoSetupSuppressed so refresh does not auto-restart setup.
        let paths = SteppePaths(root: root)
        try FileManager.default.createDirectory(at: paths.steamApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.steamApps.appendingPathComponent("common/Cossacks 3"), withIntermediateDirectories: true)
        try """
        "AppState"
        {
            "appid" "333420"
            "StateFlags" "4"
            "installdir" "Cossacks 3"
        }
        """.write(to: paths.appManifestURL(appID: GameProfile.cossacks3.steamAppID), atomically: true, encoding: .utf8)
        try Data().write(to: paths.steamApps.appendingPathComponent("common/Cossacks 3/cossacks.exe"))

        let ctrl = SteppeController(
            nativeDir: nil,
            defaults: defaults,
            rootOverride: root,
            runtime: MockRuntime(disk: .available(50_000_000_000), rosetta: false),
            pollIntervalNanoseconds: 20_000_000,
            configureGlobalLogger: false
        )
        await ctrl.refresh(allowAutoSetup: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(ctrl.phase, .settingUp)
        XCTAssertEqual(ctrl.activePrompt, .installRosetta)

        ctrl.cancelSetup()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(ctrl.phase, .needsSetup)
        XCTAssertNil(ctrl.activePrompt)

        // Calling refresh with allowAutoSetup: true after explicit cancel keeps needsSetup instead of restarting!
        await ctrl.refresh(allowAutoSetup: true)
        XCTAssertEqual(ctrl.phase, .needsSetup)

        // 3) Repair removes engine/framework markers under lock, preserves existing mic settings, and re-runs setup.
        defaults.set(true, forKey: "micGranted")
        try FileManager.default.createDirectory(at: paths.engineDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.frameworksDir, withIntermediateDirectories: true)
        try Data("engine".utf8).write(to: paths.engineMarker)
        try Data("fw".utf8).write(to: paths.frameworksMarker)

        var competingLock: InstallLock?
        if case .success(let acquired) = InstallLock.acquire(root: root) {
            competingLock = acquired
        }
        ctrl.repair()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(ctrl.phase, .failed(L("Another copy of Steppe is already working with this installation.")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.engineMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.frameworksMarker.path))
        XCTAssertEqual(ctrl.restoreOriginalGameFiles(), 0)
        competingLock = nil
        _ = competingLock

        ctrl.repair()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(ctrl.phase, .settingUp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.engineMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.frameworksMarker.path))
        XCTAssertTrue(defaults.bool(forKey: "micGranted"))
        ctrl.cancelSetup()
        try await Task.sleep(nanoseconds: 80_000_000)

        // 4) Unrelated user file in install root survives uninstall(), and rootOverride is preserved.
        let keepFile = root.appendingPathComponent("user-important-file.txt")
        try Data("do-not-delete".utf8).write(to: keepFile)

        await ctrl.uninstall()
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.engineDir.path))
        XCTAssertFalse(ctrl.isMaintaining)
        XCTAssertEqual(ctrl.paths.root.standardizedFileURL.path, root.standardizedFileURL.path)
    }

    @MainActor
    func testPlayDelaysDialogHelperUntilGameProcessIsRunning() async throws {
        final class PlayProbeState: @unchecked Sendable {
            private let lock = NSLock()
            private let manifestURL: URL
            private var _steamLaunched = false
            private var _postLaunchChecks = 0
            private var _gameWasReportedRunning = false
            private var _dialogHelperLaunches = 0
            private var _dialogHelperSawGameRunning = false

            init(manifestURL: URL) {
                self.manifestURL = manifestURL
            }

            func markSteamLaunched() {
                lock.lock()
                _steamLaunched = true
                lock.unlock()
            }

            func nextCheckGameRunning() -> GameRunningCheck {
                lock.lock()
                defer { lock.unlock() }
                guard _steamLaunched else { return .notRunning }
                _postLaunchChecks += 1
                switch _postLaunchChecks {
                case 1:
                    // Simulate Steam checking in after sign-in and discovering a pending update.
                    let updatingACF = """
                    "AppState"
                    {
                        "appid" "333420"
                        "StateFlags" "1030"
                        "installdir" "Cossacks 3"
                    }
                    """
                    try? updatingACF.write(to: manifestURL, atomically: true, encoding: .utf8)
                    return .notRunning
                case 2:
                    return .notRunning
                case 3:
                    let readyACF = """
                    "AppState"
                    {
                        "appid" "333420"
                        "StateFlags" "4"
                        "installdir" "Cossacks 3"
                    }
                    """
                    try? readyACF.write(to: manifestURL, atomically: true, encoding: .utf8)
                    _gameWasReportedRunning = true
                    return .running
                default:
                    return .notRunning
                }
            }

            func recordDialogHelperLaunch() {
                lock.lock()
                defer { lock.unlock() }
                _dialogHelperLaunches += 1
                _dialogHelperSawGameRunning = _gameWasReportedRunning
            }

            var snapshot: (launches: Int, sawRunning: Bool, checks: Int) {
                lock.lock()
                defer { lock.unlock() }
                return (_dialogHelperLaunches, _dialogHelperSawGameRunning, _postLaunchChecks)
            }
        }

        struct PlayMockRuntime: SteppeRuntime {
            let state: PlayProbeState

            func primaryDisplay() -> DisplayInfo {
                DisplayInfo(size: Resolution(width: 2560, height: 1600), scale: 2.0, maxRefreshRate: 60, name: "MockDisplay", hasNotch: false)
            }
            func diskStatus(at root: URL) async -> SystemInfo.DiskStatus { .available(50_000_000_000) }
            func acquireLock(root: URL) -> Result<InstallLock, LockFailure> { InstallLock.acquire(root: root) }
            func isRosettaInstalled() async -> Bool { true }
            func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? { nil }
            func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck {
                state.nextCheckGameRunning()
            }
            func isClientRunning(inEngine bundle: URL) async -> Bool { false }
            func isAnyProcessRunning(inEngine bundle: URL) async -> Bool { false }
            func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {}
            func killAllWine(paths: SteppePaths, environment: [String: String]) async {}
            func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {
                state.markSteamLaunched()
            }
            func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {}
            func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {
                state.recordDialogHelperLaunch()
            }
            func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? { nil }
            func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {}
            func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {}
            func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool { true }
            func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func isolatePrefix(_ prefix: URL) throws {}
            func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func ensureAudioEntitlements(engineRoot: URL) async {}
            func microphoneStatus() -> MicrophoneStatus { .notDetermined }
            @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
            @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
        }

        let fm = FileManager.default
        let paths = SteppePaths(root: root)
        let manifest = RuntimeManifest.current

        let nativeDir = root.appendingPathComponent("native", isDirectory: true)
        try fm.createDirectory(at: nativeDir, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: nativeDir.appendingPathComponent("dismiss-dialog.exe"))

        try fm.createDirectory(at: paths.wineBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: paths.wineBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.wineBinary.path)
        try ComponentMarker(name: manifest.engine.name, checksum: manifest.engine.sha256, patchRevision: manifest.patchRevision)
            .write(paths.engineMarker)

        try fm.createDirectory(at: paths.frameworksDir, withIntermediateDirectories: true)
        try Data().write(to: paths.frameworksDir.appendingPathComponent("libfreetype.6.dylib"))
        try ComponentMarker(name: manifest.template.name, checksum: manifest.template.sha256, patchRevision: manifest.patchRevision)
            .write(paths.frameworksMarker)

        try fm.createDirectory(at: paths.driveC.appendingPathComponent("windows"), withIntermediateDirectories: true)
        try Data().write(to: paths.prefixDir.appendingPathComponent("system.reg"))
        try ComponentMarker(name: "prefix", checksum: manifest.engine.sha256, patchRevision: manifest.patchRevision)
            .write(paths.prefixMarker)

        try fm.createDirectory(at: paths.steamApps.appendingPathComponent("common/Cossacks 3"), withIntermediateDirectories: true)
        try Data().write(to: paths.steamExe)
        try Data().write(to: paths.steamApps.appendingPathComponent("common/Cossacks 3/cossacks.exe"))
        let manifestURL = paths.appManifestURL(appID: GameProfile.cossacks3.steamAppID)
        try """
        "AppState"
        {
            "appid" "333420"
            "StateFlags" "4"
            "installdir" "Cossacks 3"
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let probe = PlayProbeState(manifestURL: manifestURL)
        let ctrl = SteppeController(
            nativeDir: nativeDir,
            defaults: defaults,
            rootOverride: root,
            manifest: manifest,
            runtime: PlayMockRuntime(state: probe),
            pollIntervalNanoseconds: 5_000_000,
            configureGlobalLogger: false
        )

        await ctrl.refresh(allowAutoSetup: false)
        XCTAssertEqual(ctrl.phase, .ready)
        XCTAssertEqual(probe.snapshot.launches, 0)

        ctrl.play()
        for _ in 0..<200 {
            if !ctrl.isBusy, case .ready = ctrl.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(ctrl.isBusy)
        XCTAssertEqual(ctrl.phase, .ready)
        let result = probe.snapshot
        XCTAssertEqual(result.launches, 1)
        XCTAssertTrue(result.sawRunning)
        XCTAssertGreaterThanOrEqual(result.checks, 5)
    }

    // MARK: - Regression tests for deep audit fixes

    private func seedReadyPrefix(at paths: SteppePaths, nativeDir: URL? = nil, manifest: RuntimeManifest = .current) throws {
        let fm = FileManager.default
        if let nativeDir {
            try fm.createDirectory(at: nativeDir, withIntermediateDirectories: true)
            try Data("helper".utf8).write(to: nativeDir.appendingPathComponent("dismiss-dialog.exe"))
        }
        try fm.createDirectory(at: paths.wineBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: paths.wineBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.wineBinary.path)
        try ComponentMarker(name: manifest.engine.name, checksum: manifest.engine.sha256, patchRevision: manifest.patchRevision)
            .write(paths.engineMarker)

        try fm.createDirectory(at: paths.frameworksDir, withIntermediateDirectories: true)
        try Data().write(to: paths.frameworksDir.appendingPathComponent("libfreetype.6.dylib"))
        try ComponentMarker(name: manifest.template.name, checksum: manifest.template.sha256, patchRevision: manifest.patchRevision)
            .write(paths.frameworksMarker)

        try fm.createDirectory(at: paths.driveC.appendingPathComponent("windows"), withIntermediateDirectories: true)
        try Data().write(to: paths.prefixDir.appendingPathComponent("system.reg"))
        try ComponentMarker(name: "prefix", checksum: manifest.engine.sha256, patchRevision: manifest.patchRevision)
            .write(paths.prefixMarker)

        try fm.createDirectory(at: paths.steamApps.appendingPathComponent("common/Cossacks 3"), withIntermediateDirectories: true)
        try Data().write(to: paths.steamExe)
        try Data().write(to: paths.steamApps.appendingPathComponent("common/Cossacks 3/cossacks.exe"))
        try """
        "AppState"
        {
            "appid" "333420"
            "StateFlags" "4"
            "installdir" "Cossacks 3"
        }
        """.write(to: paths.appManifestURL(appID: GameProfile.cossacks3.steamAppID), atomically: true, encoding: .utf8)
    }

    func testProcessRunnerCancellationThrowsCancellationErrorAndRunCheckedPropagatesIt() async throws {
        let sleepBin = URL(fileURLWithPath: "/bin/sleep")
        let runTask = Task {
            try await ProcessRunner.run(sleepBin, arguments: ["30"])
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        runTask.cancel()
        do {
            _ = try await runTask.value
            XCTFail("Expected CancellationError from ProcessRunner.run")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let checkedTask = Task {
            try await ProcessRunner.runChecked(sleepBin, arguments: ["30"])
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        checkedTask.cancel()
        do {
            _ = try await checkedTask.value
            XCTFail("Expected CancellationError from ProcessRunner.runChecked")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testProcessFailureRedactsBeforeTruncatingTo400Chars() {
        let stderr = "error /Users/alice/" + String(repeating: "a", count: 388)
        let failure = ProcessFailure.nonZeroExit("wine", CommandResult(exitCode: 1, stdout: "", stderr: stderr))
        let desc = failure.errorDescription ?? ""
        XCTAssertFalse(desc.contains("alice"), "path prefix must be redacted before 400-char suffix truncation: \(desc)")
        XCTAssertTrue(desc.contains("<user>"))
    }

    @MainActor
    func testPruneFrameTimesRemovesExcessAndOversizedPidFiles() throws {
        let logsDir = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let unrelated = logsDir.appendingPathComponent("steppe.log")
        try Data("keep".utf8).write(to: unrelated)

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for idx in 1...7 {
            let file = logsDir.appendingPathComponent("frames.ns.\(1000 + idx)")
            try Data(repeating: 0x41, count: 100).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: baseDate.addingTimeInterval(Double(idx * 10))], ofItemAtPath: file.path)
        }
        SteppeController.pruneFrameTimes(in: logsDir, maxTotalBytes: 10_000, maxKeepFiles: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logsDir.appendingPathComponent("frames.ns.1001").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logsDir.appendingPathComponent("frames.ns.1002").path))
        for idx in 3...7 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: logsDir.appendingPathComponent("frames.ns.\(1000 + idx)").path))
        }

        for idx in 1...3 {
            let file = logsDir.appendingPathComponent("frames.ns.\(2000 + idx)")
            try Data(repeating: 0x42, count: 600).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: baseDate.addingTimeInterval(Double(1000 + idx * 10))], ofItemAtPath: file.path)
        }
        SteppeController.pruneFrameTimes(in: logsDir, maxTotalBytes: 1_000, maxKeepFiles: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logsDir.appendingPathComponent("frames.ns.2003").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logsDir.appendingPathComponent("frames.ns.2002").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logsDir.appendingPathComponent("frames.ns.2001").path))
    }

    @MainActor
    func testForceStopOnAttachedRunningGameReturnsToReadyWithoutStalling() async throws {
        final class ForceStopState: @unchecked Sendable {
            private let lock = NSLock()
            var running = true
            var killCount = 0

            func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }
            func markKilled() { lock.lock(); running = false; killCount += 1; lock.unlock() }
            var kills: Int { lock.lock(); defer { lock.unlock() }; return killCount }
        }

        struct ForceStopRuntime: SteppeRuntime {
            let state: ForceStopState
            func primaryDisplay() -> DisplayInfo {
                DisplayInfo(size: Resolution(width: 2560, height: 1600), scale: 2.0, maxRefreshRate: 60, name: "MockDisplay", hasNotch: false)
            }
            func diskStatus(at root: URL) async -> SystemInfo.DiskStatus { .available(50_000_000_000) }
            func acquireLock(root: URL) -> Result<InstallLock, LockFailure> { InstallLock.acquire(root: root) }
            func isRosettaInstalled() async -> Bool { true }
            func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? { nil }
            func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck {
                state.isRunning() ? .running : .notRunning
            }
            func isClientRunning(inEngine bundle: URL) async -> Bool { false }
            func isAnyProcessRunning(inEngine bundle: URL) async -> Bool { state.isRunning() }
            func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {}
            func killAllWine(paths: SteppePaths, environment: [String: String]) async {
                try? await Task.sleep(nanoseconds: 20_000_000)
                state.markKilled()
            }
            func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {}
            func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {}
            func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {}
            func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? { nil }
            func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {}
            func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {}
            func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool { true }
            func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func isolatePrefix(_ prefix: URL) throws {}
            func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func ensureAudioEntitlements(engineRoot: URL) async {}
            func microphoneStatus() -> MicrophoneStatus { .notDetermined }
            @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
            @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
        }

        let paths = SteppePaths(root: root)
        try seedReadyPrefix(at: paths)
        let state = ForceStopState()
        let ctrl = SteppeController(
            nativeDir: nil,
            defaults: defaults,
            rootOverride: root,
            runtime: ForceStopRuntime(state: state),
            pollIntervalNanoseconds: 10_000_000,
            configureGlobalLogger: false
        )

        await ctrl.refresh(allowAutoSetup: false)
        guard case .playing = ctrl.phase else {
            return XCTFail("Expected controller to attach to running game, got \(ctrl.phase)")
        }

        ctrl.forceStop()
        for _ in 0..<200 {
            if !ctrl.isBusy, case .ready = ctrl.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(ctrl.isBusy)
        XCTAssertEqual(ctrl.phase, .ready)
        XCTAssertEqual(state.kills, 1)
    }

    @MainActor
    func testRunPlayFailsEarlyWhenSteamExitsBeforeGameStarts() async throws {
        struct DeadSteamRuntime: SteppeRuntime {
            func primaryDisplay() -> DisplayInfo {
                DisplayInfo(size: Resolution(width: 2560, height: 1600), scale: 2.0, maxRefreshRate: 60, name: "MockDisplay", hasNotch: false)
            }
            func diskStatus(at root: URL) async -> SystemInfo.DiskStatus { .available(50_000_000_000) }
            func acquireLock(root: URL) -> Result<InstallLock, LockFailure> { InstallLock.acquire(root: root) }
            func isRosettaInstalled() async -> Bool { true }
            func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? { nil }
            func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck { .notRunning }
            func isClientRunning(inEngine bundle: URL) async -> Bool { false }
            func isAnyProcessRunning(inEngine bundle: URL) async -> Bool { false }
            func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {}
            func killAllWine(paths: SteppePaths, environment: [String: String]) async {}
            func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {}
            func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {}
            func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {}
            func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? { nil }
            func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {}
            func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {}
            func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool { true }
            func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func isolatePrefix(_ prefix: URL) throws {}
            func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func ensureAudioEntitlements(engineRoot: URL) async {}
            func microphoneStatus() -> MicrophoneStatus { .notDetermined }
            @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
            @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
        }

        let paths = SteppePaths(root: root)
        try seedReadyPrefix(at: paths)
        let ctrl = SteppeController(
            nativeDir: nil,
            defaults: defaults,
            rootOverride: root,
            runtime: DeadSteamRuntime(),
            pollIntervalNanoseconds: 5_000_000,
            steamLaunchExitGraceNanoseconds: 10_000_000,
            configureGlobalLogger: false
        )

        await ctrl.refresh(allowAutoSetup: false)
        XCTAssertEqual(ctrl.phase, .ready)
        ctrl.play()

        for _ in 0..<200 {
            if !ctrl.isBusy, case .ready = ctrl.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(ctrl.isBusy)
        XCTAssertEqual(ctrl.phase, .ready)
        XCTAssertEqual(ctrl.lastSessionNote, SetupError.gameDidNotStart.localizedDescription)
    }

    @MainActor
    func testRestoreOriginalGameFilesClearsPatchLogAndSkipsSteamUpdatedDLLs() async throws {
        struct IdleRuntime: SteppeRuntime {
            func primaryDisplay() -> DisplayInfo {
                DisplayInfo(size: Resolution(width: 2560, height: 1600), scale: 2.0, maxRefreshRate: 60, name: "MockDisplay", hasNotch: false)
            }
            func diskStatus(at root: URL) async -> SystemInfo.DiskStatus { .available(50_000_000_000) }
            func acquireLock(root: URL) -> Result<InstallLock, LockFailure> { InstallLock.acquire(root: root) }
            func isRosettaInstalled() async -> Bool { true }
            func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? { nil }
            func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck { .notRunning }
            func isClientRunning(inEngine bundle: URL) async -> Bool { false }
            func isAnyProcessRunning(inEngine bundle: URL) async -> Bool { false }
            func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {}
            func killAllWine(paths: SteppePaths, environment: [String: String]) async {}
            func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {}
            func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {}
            func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {}
            func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? { nil }
            func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {}
            func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {}
            func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool { true }
            func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func isolatePrefix(_ prefix: URL) throws {}
            func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func ensureAudioEntitlements(engineRoot: URL) async {}
            func microphoneStatus() -> MicrophoneStatus { .notDetermined }
            @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
            @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
        }

        let paths = SteppePaths(root: root)
        let nativeDir = root.appendingPathComponent("native", isDirectory: true)
        try seedReadyPrefix(at: paths, nativeDir: nativeDir)
        let gameDir = try XCTUnwrap(SteamKit(paths: paths).gameDirectory)

        var known: [String: String] = [:]
        for name in GameFiles.libraryNames {
            let orig = Data("orig-\(name)".utf8)
            try orig.write(to: gameDir.appendingPathComponent(name))
            try Data("fast-\(name)".utf8).write(to: nativeDir.appendingPathComponent(name))
            known[name] = Hashing.sha256(of: orig)
        }
        _ = GameFiles.installSpeedLibraries(from: nativeDir, into: gameDir, knownOriginals: known)

        // Simulate Steam updating ogg.dll without Steppe's knowledge.
        try Data("steam-new-ogg".utf8).write(to: gameDir.appendingPathComponent("ogg.dll"))

        try FileManager.default.createDirectory(at: paths.patchLogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("0x004d1870 applied\n".utf8).write(to: paths.patchLogFile)

        let ctrl = SteppeController(
            nativeDir: nativeDir,
            defaults: defaults,
            rootOverride: root,
            runtime: IdleRuntime(),
            configureGlobalLogger: false
        )
        await ctrl.refresh(allowAutoSetup: false)
        XCTAssertFalse(ctrl.patchReport.isEmpty)

        let restored = ctrl.restoreOriginalGameFiles()
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(try String(contentsOf: gameDir.appendingPathComponent("ogg.dll")), "steam-new-ogg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("ogg.dll.steppe-orig").path))
        XCTAssertEqual(try String(contentsOf: gameDir.appendingPathComponent("vorbis.dll")), "orig-vorbis.dll")
        XCTAssertEqual(try String(contentsOf: gameDir.appendingPathComponent("vorbisfile.dll")), "orig-vorbisfile.dll")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.patchLogFile.path))
        XCTAssertTrue(ctrl.patchReport.isEmpty)
    }

    func testSteamKitGameDirectoryRejectsPathTraversal() throws {
        let paths = SteppePaths(root: root)
        try FileManager.default.createDirectory(at: paths.steamApps, withIntermediateDirectories: true)
        let manifestURL = paths.appManifestURL(appID: GameProfile.cossacks3.steamAppID)

        for badDir in ["../../outside", ".", ".."] {
            try """
            "AppState"
            {
                "appid" "333420"
                "StateFlags" "4"
                "installdir" "\(badDir)"
            }
            """.write(to: manifestURL, atomically: true, encoding: .utf8)
            XCTAssertNil(SteamKit(paths: paths).gameDirectory, "Expected nil for traversal dir \(badDir)")
        }

        try """
        "AppState"
        {
            "appid" "333420"
            "StateFlags" "4"
            "installdir" "Cossacks 3"
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(SteamKit(paths: paths).gameDirectory?.lastPathComponent, "Cossacks 3")
    }

    func testProfileConfigInsertsMissingMultithreadedSettingInsideEngineBlock() throws {
        let lf = """
        section.begin
           Engine : struct.begin
              ScreenResolution : struct.begin
                 Width = 1920
                 Height = 1080
              struct.end
              Sound : struct.begin
                 Master = 1
              struct.end
           struct.end
        section.end
        """
        for text in [lf, lf.replacingOccurrences(of: "\n", with: "\r\n")] {
            let disabled = try XCTUnwrap(ProfileConfig.settingMultithreaded(false, in: text))
            XCTAssertEqual(ProfileConfig.multithreaded(in: disabled), false)
            let enabled = try XCTUnwrap(ProfileConfig.settingMultithreaded(true, in: disabled))
            XCTAssertEqual(ProfileConfig.multithreaded(in: enabled), true)
            if text.contains("\r\n") {
                XCTAssertFalse(disabled.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
            } else {
                XCTAssertFalse(disabled.contains("\r"))
            }
            let engineEndIdx = try XCTUnwrap(disabled.range(of: "section.end")?.lowerBound)
            let mtIdx = try XCTUnwrap(disabled.range(of: "UseMultithreadedMode = False")?.lowerBound)
            let soundEndIdx = try XCTUnwrap(disabled.range(of: "Master = 1")?.upperBound)
            XCTAssertGreaterThan(mtIdx, soundEndIdx)
            XCTAssertLessThan(mtIdx, engineEndIdx)
        }
        XCTAssertNil(ProfileConfig.settingMultithreaded(true, in: "section.begin\nsection.end\n"))
    }

    func testWineEnvironmentToolExcludesGLFixAndFrameTimes() throws {
        let nativeDir = root.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDir, withIntermediateDirectories: true)
        try Data().write(to: nativeDir.appendingPathComponent("libglfix.dylib"))

        var settings = AppSettings()
        settings.enableSpeedPatches = true
        settings.recordFrameTimes = true
        settings.experimentalMathPatches = true

        let builder = WineEnvironment(paths: SteppePaths(root: root), nativeDir: nativeDir)
        let gameEnv = builder.game(settings: settings)
        XCTAssertNotNil(gameEnv["DYLD_INSERT_LIBRARIES"])

        let toolEnv = builder.tool()
        XCTAssertNil(toolEnv["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(toolEnv["GLFIX_REMAP"])
        XCTAssertNil(toolEnv["GLFIX_FRAMETIMES"])
        XCTAssertNil(toolEnv["STEPPE_PATCH_LOG"])
        XCTAssertNil(toolEnv["STEPPE_MATH_PATCHES"])
        XCTAssertEqual(toolEnv["C3_VORBIS_CACHE"], "0")
    }

    func testDownloaderHandles206WithoutContentLengthAndImmediateCancel() async throws {
        final class PartialAndSlowServer: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var payload = Data((0..<40_000).map { UInt8($0 % 199) })
            nonisolated(unsafe) static var mode = "partial"
            nonisolated(unsafe) static var activeLock = NSLock()
            nonisolated(unsafe) static var cancelled = false

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func stopLoading() {
                Self.activeLock.lock()
                Self.cancelled = true
                Self.activeLock.unlock()
            }

            override func startLoading() {
                let url = request.url!
                if Self.mode == "hang" {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "1000"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    return
                }
                let range = request.value(forHTTPHeaderField: "Range") ?? ""
                let start = Int(range.dropFirst(6).split(separator: "-").first ?? "") ?? 0
                let body = Self.payload.subdata(in: start..<Self.payload.count)
                // Return 206 without Content-Length so expectedContentLength is -1.
                let resp = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [:])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PartialAndSlowServer.self]
        let dest = root.appendingPathComponent("dl/partial.bin")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PartialAndSlowServer.payload.prefix(10_000).write(to: dest.appendingPathExtension("part"))

        final class ProgressBox: @unchecked Sendable {
            private let lock = NSLock()
            var totals: [Int64] = []
            func append(_ total: Int64) { lock.lock(); totals.append(total); lock.unlock() }
        }
        let progressBox = ProgressBox()
        PartialAndSlowServer.mode = "partial"
        try await Downloader.download(
            url: URL(string: "https://example.invalid/partial.bin")!,
            to: dest,
            expectedSHA256: Hashing.sha256(of: PartialAndSlowServer.payload),
            expectedSize: Int64(PartialAndSlowServer.payload.count),
            configuration: cfg,
            retryDelayUnit: 1_000_000
        ) { p in
            progressBox.append(p.total)
        }
        XCTAssertEqual(try Data(contentsOf: dest), PartialAndSlowServer.payload)
        XCTAssertTrue(progressBox.totals.allSatisfy { $0 >= 0 })

        PartialAndSlowServer.mode = "hang"
        let cancelDest = root.appendingPathComponent("dl/cancel.bin")
        let cancelTask = Task {
            let cancelCfg = URLSessionConfiguration.ephemeral
            cancelCfg.protocolClasses = [PartialAndSlowServer.self]
            try await Downloader.download(
                url: URL(string: "https://example.invalid/cancel.bin")!,
                to: cancelDest,
                expectedSHA256: nil,
                expectedSize: nil,
                configuration: cancelCfg,
                retryDelayUnit: 1_000_000
            ) { _ in }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelTask.cancel()
        do {
            try await cancelTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let preCancelDest = root.appendingPathComponent("dl/precancel.bin")
        let preCancelledTask = Task {
            let preCfg = URLSessionConfiguration.ephemeral
            preCfg.protocolClasses = [PartialAndSlowServer.self]
            withUnsafeCurrentTask { $0?.cancel() }
            try await Downloader.download(
                url: URL(string: "https://example.invalid/precancel.bin")!,
                to: preCancelDest,
                expectedSHA256: nil,
                expectedSize: nil,
                configuration: preCfg,
                retryDelayUnit: 1_000_000
            ) { _ in }
        }
        do {
            try await preCancelledTask.value
            XCTFail("Expected CancellationError for pre-cancelled download")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - PR #3/#4 integrated lifecycle & edge-case tests

    @MainActor
    func testForceStopTracksStoppingStateBlocksPlayAndUninstallWaits() async throws {
        final class StopRaceState: @unchecked Sendable {
            private let lock = NSLock()
            private var _killEntered = false
            private var _allowKillFinish = false
            private var _launchCount = 0
            private var _killCount = 0
            private var _running = true

            func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return _running }
            func markKillEntered() { lock.lock(); _killEntered = true; _killCount += 1; lock.unlock() }
            func isKillEntered() -> Bool { lock.lock(); defer { lock.unlock() }; return _killEntered }
            func allowKillFinish() { lock.lock(); _allowKillFinish = true; _running = false; lock.unlock() }
            func canKillFinish() -> Bool { lock.lock(); defer { lock.unlock() }; return _allowKillFinish }
            func noteLaunch() { lock.lock(); _launchCount += 1; lock.unlock() }
            var launches: Int { lock.lock(); defer { lock.unlock() }; return _launchCount }
            var kills: Int { lock.lock(); defer { lock.unlock() }; return _killCount }
        }

        struct StopRaceRuntime: SteppeRuntime {
            let state: StopRaceState
            func primaryDisplay() -> DisplayInfo {
                DisplayInfo(size: Resolution(width: 2560, height: 1600), scale: 2.0, maxRefreshRate: 60, name: "MockDisplay", hasNotch: false)
            }
            func diskStatus(at root: URL) async -> SystemInfo.DiskStatus { .available(50_000_000_000) }
            func acquireLock(root: URL) -> Result<InstallLock, LockFailure> { InstallLock.acquire(root: root) }
            func isRosettaInstalled() async -> Bool { true }
            func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? { nil }
            func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck {
                state.isRunning() ? .running : .notRunning
            }
            func isClientRunning(inEngine bundle: URL) async -> Bool { false }
            func isAnyProcessRunning(inEngine bundle: URL) async -> Bool { state.isRunning() }
            func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {}
            func killAllWine(paths: SteppePaths, environment: [String: String]) async {
                state.markKillEntered()
                while !state.canKillFinish() {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {
                state.noteLaunch()
            }
            func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {}
            func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {}
            func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? { nil }
            func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {}
            func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {}
            func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool { true }
            func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func isolatePrefix(_ prefix: URL) throws {}
            func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func ensureAudioEntitlements(engineRoot: URL) async {}
            func microphoneStatus() -> MicrophoneStatus { .notDetermined }
            @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
            @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
        }

        let paths = SteppePaths(root: root)
        try seedReadyPrefix(at: paths)
        let state = StopRaceState()
        let ctrl = SteppeController(
            nativeDir: nil,
            defaults: defaults,
            rootOverride: root,
            runtime: StopRaceRuntime(state: state),
            pollIntervalNanoseconds: 10_000_000,
            configureGlobalLogger: false
        )

        await ctrl.refresh(allowAutoSetup: false)
        guard case .playing = ctrl.phase else {
            return XCTFail("Expected attached playing phase, got \(ctrl.phase)")
        }

        ctrl.forceStop()
        XCTAssertTrue(ctrl.isStopping)
        XCTAssertTrue(ctrl.isBusy)

        for _ in 0..<100 where !state.isKillEntered() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(state.isKillEntered())
        // While forceStop is still stopping processes, Ready has not appeared and play()/forceStop() are blocked.
        ctrl.forceStop()
        ctrl.play()
        XCTAssertEqual(state.launches, 0)
        XCTAssertEqual(state.kills, 1)

        // Start uninstall while forceStop is still running; uninstall must wait for stopTask before deleting.
        let uninstallTask = Task { await ctrl.uninstall() }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.engineDir.path), "uninstall must wait for forceStop before deleting")

        state.allowKillFinish()
        await uninstallTask.value
        XCTAssertFalse(ctrl.isStopping)
        XCTAssertFalse(ctrl.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.engineDir.path))
    }

    @MainActor
    func testCancelledSetupDetachesSteamShutdownAndFailedSetupStopsPrefix() async throws {
        final class SetupCleanupState: @unchecked Sendable {
            private let lock = NSLock()
            private var _shutdownObservedCancellation = false
            private var _shutdownCount = 0
            private var _killCount = 0
            private var _failCreatePrefix = false

            var failCreatePrefix: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _failCreatePrefix }
                set { lock.lock(); _failCreatePrefix = newValue; lock.unlock() }
            }

            func recordShutdown(cancelled: Bool) {
                lock.lock()
                _shutdownObservedCancellation = cancelled
                _shutdownCount += 1
                lock.unlock()
            }

            func recordKill() {
                lock.lock()
                _killCount += 1
                lock.unlock()
            }

            var shutdownObservedCancellation: Bool { lock.lock(); defer { lock.unlock() }; return _shutdownObservedCancellation }
            var shutdownCount: Int { lock.lock(); defer { lock.unlock() }; return _shutdownCount }
            var killCount: Int { lock.lock(); defer { lock.unlock() }; return _killCount }
        }

        struct SetupCleanupRuntime: SteppeRuntime {
            let state: SetupCleanupState
            func primaryDisplay() -> DisplayInfo {
                DisplayInfo(size: Resolution(width: 2560, height: 1600), scale: 2.0, maxRefreshRate: 60, name: "MockDisplay", hasNotch: false)
            }
            func diskStatus(at root: URL) async -> SystemInfo.DiskStatus { .available(50_000_000_000) }
            func acquireLock(root: URL) -> Result<InstallLock, LockFailure> { InstallLock.acquire(root: root) }
            func isRosettaInstalled() async -> Bool { false }
            func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? { nil }
            func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck { .notRunning }
            func isClientRunning(inEngine bundle: URL) async -> Bool { false }
            func isAnyProcessRunning(inEngine bundle: URL) async -> Bool { false }
            func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {
                state.recordShutdown(cancelled: Task.isCancelled)
            }
            func killAllWine(paths: SteppePaths, environment: [String: String]) async {
                state.recordKill()
            }
            func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {}
            func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {}
            func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {}
            func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? { nil }
            func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {}
            func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {}
            func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool { false }
            func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {
                if state.failCreatePrefix { throw SetupError.engineLayout }
            }
            func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func isolatePrefix(_ prefix: URL) throws {}
            func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func ensureAudioEntitlements(engineRoot: URL) async {}
            func microphoneStatus() -> MicrophoneStatus { .notDetermined }
            @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
            @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
        }

        // Case 1: Cancelled setup shuts down Steam in a detached task so Task.isCancelled is false.
        let state1 = SetupCleanupState()
        let ctrl1 = SteppeController(
            nativeDir: nil,
            defaults: defaults,
            rootOverride: root,
            runtime: SetupCleanupRuntime(state: state1),
            pollIntervalNanoseconds: 10_000_000,
            configureGlobalLogger: false
        )
        ctrl1.startSetup()
        try await Task.sleep(nanoseconds: 50_000_000)
        ctrl1.cancelSetup()
        for _ in 0..<100 where ctrl1.isBusy {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(state1.shutdownCount, 1)
        XCTAssertFalse(state1.shutdownObservedCancellation)
        XCTAssertEqual(ctrl1.phase, .needsSetup)

        // Case 2: External drive error fails setup and triggers stopPrefix() so leftover processes do not linger.
        struct FailingDiskRuntime: SteppeRuntime {
            let state: SetupCleanupState
            func primaryDisplay() -> DisplayInfo {
                DisplayInfo(size: Resolution(width: 2560, height: 1600), scale: 2.0, maxRefreshRate: 60, name: "MockDisplay", hasNotch: false)
            }
            func diskStatus(at root: URL) async -> SystemInfo.DiskStatus { .externalVolumeUnmounted("OfflineDisk") }
            func acquireLock(root: URL) -> Result<InstallLock, LockFailure> { InstallLock.acquire(root: root) }
            func isRosettaInstalled() async -> Bool { true }
            func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? { nil }
            func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck { .notRunning }
            func isClientRunning(inEngine bundle: URL) async -> Bool { false }
            func isAnyProcessRunning(inEngine bundle: URL) async -> Bool { false }
            func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {}
            func killAllWine(paths: SteppePaths, environment: [String: String]) async { state.recordKill() }
            func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {}
            func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {}
            func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {}
            func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? { nil }
            func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {}
            func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {}
            func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool { false }
            func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func isolatePrefix(_ prefix: URL) throws {}
            func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func ensureAudioEntitlements(engineRoot: URL) async {}
            func microphoneStatus() -> MicrophoneStatus { .notDetermined }
            @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
            @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
        }
        let failState = SetupCleanupState()
        let ctrl3 = SteppeController(
            nativeDir: nil,
            defaults: defaults,
            rootOverride: root,
            runtime: FailingDiskRuntime(state: failState),
            pollIntervalNanoseconds: 10_000_000,
            configureGlobalLogger: false
        )
        ctrl3.startSetup()
        for _ in 0..<100 where ctrl3.isBusy {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(failState.killCount, 1)
    }

    @MainActor
    func testOpenSteamDoesNotLaunchAfterSetupCancelled() async throws {
        final class OpenSteamRaceState: @unchecked Sendable {
            private let lock = NSLock()
            private var _allowEntFinish = false
            private var _entEntered = false
            private var _launches = 0

            func markEntEntered() { lock.lock(); _entEntered = true; lock.unlock() }
            func isEntEntered() -> Bool { lock.lock(); defer { lock.unlock() }; return _entEntered }
            func allowEntFinish() { lock.lock(); _allowEntFinish = true; lock.unlock() }
            func canEntFinish() -> Bool { lock.lock(); defer { lock.unlock() }; return _allowEntFinish }
            func recordLaunch() { lock.lock(); _launches += 1; lock.unlock() }
            var launches: Int { lock.lock(); defer { lock.unlock() }; return _launches }
        }

        struct OpenSteamRaceRuntime: SteppeRuntime {
            let state: OpenSteamRaceState
            func primaryDisplay() -> DisplayInfo {
                DisplayInfo(size: Resolution(width: 2560, height: 1600), scale: 2.0, maxRefreshRate: 60, name: "MockDisplay", hasNotch: false)
            }
            func diskStatus(at root: URL) async -> SystemInfo.DiskStatus { .available(50_000_000_000) }
            func acquireLock(root: URL) -> Result<InstallLock, LockFailure> { InstallLock.acquire(root: root) }
            func isRosettaInstalled() async -> Bool { false }
            func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? { nil }
            func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck { .notRunning }
            func isClientRunning(inEngine bundle: URL) async -> Bool { false }
            func isAnyProcessRunning(inEngine bundle: URL) async -> Bool { false }
            func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {}
            func killAllWine(paths: SteppePaths, environment: [String: String]) async {}
            func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {
                state.recordLaunch()
            }
            func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {}
            func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {}
            func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? { nil }
            func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {}
            func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {}
            func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool { false }
            func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func isolatePrefix(_ prefix: URL) throws {}
            func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func ensureAudioEntitlements(engineRoot: URL) async {
                state.markEntEntered()
                while !state.canEntFinish() && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            func microphoneStatus() -> MicrophoneStatus { .notDetermined }
            @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
            @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
        }

        let state = OpenSteamRaceState()
        let ctrl = SteppeController(
            nativeDir: nil,
            defaults: defaults,
            rootOverride: root,
            runtime: OpenSteamRaceRuntime(state: state),
            pollIntervalNanoseconds: 10_000_000,
            configureGlobalLogger: false
        )
        ctrl.startSetup()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(ctrl.phase, .settingUp)

        ctrl.openSteam()
        for _ in 0..<100 where !state.isEntEntered() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(state.isEntEntered())

        ctrl.cancelSetup()
        state.allowEntFinish()
        for _ in 0..<100 where ctrl.isBusy {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(state.launches, 0, "openSteam must never launch Steam after setup was cancelled")
    }

    @MainActor
    func testUninstallPreservesLockIfTargetDeletionFailsAndRemovesEmptyRootAtomically() async throws {
        struct IdleRuntime: SteppeRuntime {
            func primaryDisplay() -> DisplayInfo {
                DisplayInfo(size: Resolution(width: 2560, height: 1600), scale: 2.0, maxRefreshRate: 60, name: "MockDisplay", hasNotch: false)
            }
            func diskStatus(at root: URL) async -> SystemInfo.DiskStatus { .available(50_000_000_000) }
            func acquireLock(root: URL) -> Result<InstallLock, LockFailure> { InstallLock.acquire(root: root) }
            func isRosettaInstalled() async -> Bool { true }
            func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? { nil }
            func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck { .notRunning }
            func isClientRunning(inEngine bundle: URL) async -> Bool { false }
            func isAnyProcessRunning(inEngine bundle: URL) async -> Bool { false }
            func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {}
            func killAllWine(paths: SteppePaths, environment: [String: String]) async {}
            func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {}
            func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {}
            func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {}
            func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? { nil }
            func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {}
            func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {}
            func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool { true }
            func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {}
            func isolatePrefix(_ prefix: URL) throws {}
            func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {}
            func ensureAudioEntitlements(engineRoot: URL) async {}
            func microphoneStatus() -> MicrophoneStatus { .notDetermined }
            @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
            @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus { .notDetermined }
        }

        // Case 1: Empty install root (no unrelated user files) is removed cleanly including .steppe.lock.
        let cleanRoot = root.appendingPathComponent("clean-uninstall", isDirectory: true)
        let paths1 = SteppePaths(root: cleanRoot)
        try paths1.ensureDirectories()
        let ctrl1 = SteppeController(
            nativeDir: nil,
            defaults: defaults,
            rootOverride: cleanRoot,
            runtime: IdleRuntime(),
            pollIntervalNanoseconds: 10_000_000,
            configureGlobalLogger: false
        )
        await ctrl1.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanRoot.path))

        // Case 2: Read-only engine subdirectory containing file blocks deletion while root remains lockable; .steppe.lock is kept.
        let blockedRoot = root.appendingPathComponent("blocked-uninstall", isDirectory: true)
        let paths2 = SteppePaths(root: blockedRoot)
        try paths2.ensureDirectories()
        try FileManager.default.createDirectory(at: paths2.engineDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: paths2.engineDir.appendingPathComponent("file.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths2.engineDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths2.engineDir.path) }

        let ctrl2 = SteppeController(
            nativeDir: nil,
            defaults: defaults,
            rootOverride: blockedRoot,
            runtime: IdleRuntime(),
            pollIntervalNanoseconds: 10_000_000,
            configureGlobalLogger: false
        )
        await ctrl2.uninstall()
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockedRoot.appendingPathComponent(".steppe.lock").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths2.engineDir.path))
    }
}
