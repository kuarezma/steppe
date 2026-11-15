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
}
