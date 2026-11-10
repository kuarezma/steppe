import XCTest
@testable import SteppeCore

/// A long-running program built for the tests. Copies of system binaries such as `/bin/sleep` cannot stand in
/// for it: macOS kills them when they are started from another location.
enum TestSleeper {
    /// Compiles the program straight to `url`; the file name there is what `ps` reports (for example `cossacks.exe`).
    static func install(at url: URL) throws {
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-x", "c", "-", "-o", url.path]
        let source = Pipe()
        compiler.standardInput = source
        try compiler.run()
        try source.fileHandleForWriting.write(contentsOf: Data("#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n".utf8))
        try source.fileHandleForWriting.close()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// A complete install tree whose "Wine" is a shell script and whose "game" is `TestSleeper`, so the
/// controller's real launch, attach, force-quit and uninstall paths run without Wine, Steam or the network.
private struct FakeInstall {
    let root: URL
    let paths: SteppePaths

    var gameBinary: URL { paths.wineBundle.appendingPathComponent("bin/cossacks.exe") }

    static func make() async throws -> FakeInstall {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("steppe-ctl-\(UUID().uuidString)", isDirectory: true)
        let install = FakeInstall(root: root, paths: SteppePaths(root: root))
        let paths = install.paths
        let manifest = RuntimeManifest.current

        // Engine: `wine … -applaunch …` becomes the game process and `-shutdown` closes "Steam"; the rest is a no-op.
        let bin = paths.wineBundle.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try TestSleeper.install(at: install.gameBinary)
        let wine = """
        #!/bin/sh
        case "$*" in
          *-applaunch*) exec "$(dirname "$0")/cossacks.exe" ;;
          *-shutdown*) pkill -f "$(dirname "$0")/steam.exe" ;;
        esac
        exit 0
        """
        try Data(wine.utf8).write(to: paths.wineBinary)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: paths.wineserverBinary)
        for script in [paths.wineBinary, paths.wineserverBinary] {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        // A driver that already carries the patched bytes and a valid ad-hoc signature.
        let driver = paths.wineBundle.appendingPathComponent(manifest.winemac.relativePath)
        try fm.createDirectory(at: driver.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 240_000)
        for patch in manifest.winemac.patches {
            bytes.replaceSubrange(patch.offset..<(patch.offset + patch.replacement.count), with: patch.replacement)
        }
        try Data(bytes).write(to: driver)
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", driver.path], timeout: 60)
        try ComponentMarker(name: manifest.engine.name, checksum: manifest.engine.sha256, patchRevision: manifest.patchRevision)
            .write(paths.engineMarker)

        try fm.createDirectory(at: paths.frameworksDir, withIntermediateDirectories: true)
        try Data().write(to: paths.frameworksDir.appendingPathComponent("libfreetype.6.dylib"))
        try ComponentMarker(name: manifest.template.name, checksum: manifest.template.sha256, patchRevision: manifest.patchRevision)
            .write(paths.frameworksMarker)

        try fm.createDirectory(at: paths.driveC.appendingPathComponent("windows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.driveC.appendingPathComponent("users/steppe"), withIntermediateDirectories: true)
        try Data().write(to: paths.prefixDir.appendingPathComponent("system.reg"))
        try ComponentMarker(name: "prefix", checksum: manifest.engine.sha256, patchRevision: manifest.patchRevision)
            .write(paths.prefixMarker)

        let gameDir = paths.steamApps.appendingPathComponent("common/Cossacks 3", isDirectory: true)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try Data().write(to: paths.steamExe)
        try Data().write(to: gameDir.appendingPathComponent("cossacks.exe"))
        let acf = "\"AppState\"\n{\n\t\"appid\"\t\t\"\(manifest.steam.appID)\"\n\t\"StateFlags\"\t\t\"4\"\n\t\"installdir\"\t\t\"Cossacks 3\"\n}\n"
        try Data(acf.utf8).write(to: paths.appManifestURL(appID: manifest.steam.appID))
        return install
    }

    /// Starts the "game" the way a previous Steppe session would have left it running.
    func startGame() throws -> Process { try start(gameBinary) }

    /// Starts a process that the scanner reports as `steam.exe` of this engine.
    func startSteam() throws -> Process {
        let binary = gameBinary.deletingLastPathComponent().appendingPathComponent("steam.exe")
        try TestSleeper.install(at: binary)
        return try start(binary)
    }

    private func start(_ binary: URL) throws -> Process {
        let process = Process()
        process.executableURL = binary
        try process.run()
        return process
    }

    func destroy() async {
        for process in await ProcessScanner.processes(inEngine: paths.wineBundle) { kill(process.pid, SIGKILL) }
        try? FileManager.default.removeItem(at: root)
    }
}

/// Preferences that live in memory: a named suite leaves an empty plist in `~/Library/Preferences` after every run.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

@MainActor
final class ControllerLifecycleTests: XCTestCase {
    private var install: FakeInstall!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        // On any other Mac the controller reports "unsupported" and never looks at the install.
        try XCTSkipUnless(SystemInfo.detect().isAppleSilicon
            && ProcessInfo.processInfo.isOperatingSystemAtLeast(SteppeController.minimumMacOS), "needs a Mac that Steppe supports")
        install = try await FakeInstall.make()
        defaults = MemoryDefaults()
    }

    override func tearDown() async throws {
        await install?.destroy()
    }

    private func makeController() -> SteppeController {
        SteppeController(nativeDir: nil, defaults: defaults, rootOverride: install.root)
    }

    private func wait(_ seconds: TimeInterval, for what: String, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func isRunning(_ controller: SteppeController) -> Bool { controller.phase == .playing(L("Running")) }

    func testFixtureIsSeenAsACompleteInstall() async {
        let controller = makeController()
        await controller.refresh()
        XCTAssertEqual(controller.phase, .ready)
    }

    func testForceQuitEndsTheSessionWithoutAnErrorNote() async {
        let controller = makeController()
        await controller.refresh()
        // The cancellation reaches the launch task either while it scans for the game (right away) or while it
        // sleeps between two scans (a moment later); both must end the same way.
        for delay in [0.0, 1.0] {
            controller.play()
            await wait(30, for: "the game to run") { isRunning(controller) }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            controller.forceStop()
            // Ready is shown only when the stop is over: the next round's launch, right after it, must survive.
            await wait(30, for: "the session to end") { controller.phase == .ready }
            XCTAssertNil(controller.lastSessionNote, "a deliberate Force Quit is not a failure (delay \(delay))")
            let stillRunning = await ProcessScanner.isGameRunning(inEngine: install.paths.wineBundle)
            XCTAssertFalse(stillRunning, "Ready must mean the game is gone (delay \(delay))")
        }
    }

    func testAStaleRefreshResultNeverReplacesARunningLaunch() async {
        let controller = makeController()
        await controller.refresh()
        controller.play()
        // What a refresh that started before `play()` would report once its checks return.
        controller.applyRefresh(ready: true, gameRunning: false)
        guard case .playing = controller.phase else { return XCTFail("phase became \(controller.phase)") }

        await wait(30, for: "the game to run") { isRunning(controller) }
        controller.forceStop()
        await wait(30, for: "the session to end") { controller.phase == .ready }
    }

    func testUninstallDoesNotWaitForAGameItOnlyAttachedTo() async throws {
        let game = try install.startGame()
        defer { if game.isRunning { game.terminate() } }
        let controller = makeController()
        await wait(10, for: "the game process") { game.isRunning }
        await controller.refresh()
        XCTAssertTrue(isRunning(controller), "refresh must attach to the running game, phase is \(controller.phase)")

        let started = Date()
        await controller.uninstall()
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "uninstall must stop the game instead of waiting for it")
        XCTAssertEqual(controller.phase, .needsSetup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.paths.engineDir.path))
    }

    func testCleanupStillClosesSteamAfterTheTaskWasCancelled() async throws {
        let steam = try install.startSteam()
        defer { if steam.isRunning { steam.terminate() } }
        let controller = makeController()
        let kit = SteamKit(paths: install.paths)
        await wait(10, for: "the Steam process") { steam.isRunning }
        let seen = await kit.isClientRunning()
        XCTAssertTrue(seen)

        // What the cancelled setup or launch task does on its way out.
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.shutDownSteam()
        }
        await cancelled.value

        let left = await ProcessScanner.processes(inEngine: install.paths.wineBundle)
        XCTAssertTrue(left.isEmpty, "Steam must not be left running after a cancelled setup")
    }

    func testUninstallRightAfterAForceQuitWaitsForTheStop() async {
        let controller = makeController()
        await controller.refresh()
        controller.play()
        await wait(30, for: "the game to run") { isRunning(controller) }

        controller.forceStop()
        await controller.uninstall()

        XCTAssertEqual(controller.phase, .needsSetup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.paths.engineDir.path))
        let left = await ProcessScanner.processes(inEngine: install.paths.wineBundle)
        XCTAssertTrue(left.isEmpty)
        // The Force Quit is over too; its kill cannot hit whatever uses the install folder next.
        XCTAssertFalse(controller.isStopping, "the stop was still pending when the uninstall gave up the install lock")
    }

    func testAFailedUninstallIsReportedAndNothingIsInstalledAgain() async throws {
        // The game cannot be deleted: what is left looks like an install whose components only need an update.
        let fm = FileManager.default
        let locked = [install.paths.steamApps.appendingPathComponent("common/Cossacks 3"), install.paths.steamApps]
        for directory in locked { try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path) }
        defer { for directory in locked.reversed() { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) } }
        let controller = makeController()
        await controller.refresh()

        await controller.uninstall()

        guard case .failed = controller.phase else { return XCTFail("phase became \(controller.phase)") }
        XCTAssertTrue(fm.fileExists(atPath: install.paths.steamApps.path))
        try await Task.sleep(nanoseconds: 300_000_000)
        guard case .failed = controller.phase else { return XCTFail("phase became \(controller.phase)") }
    }

    func testUninstallKeepsTheChosenInstallLocation() async {
        // No override: the location comes from the stored preference, like in the app.
        defaults.set(install.root.path, forKey: "installRoot")
        let controller = SteppeController(nativeDir: nil, defaults: defaults)
        XCTAssertEqual(controller.paths.root.path, install.root.path)

        await controller.uninstall()

        XCTAssertEqual(controller.phase, .needsSetup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.paths.engineDir.path))
        // Whatever is installed next goes to `paths.root`; the next launch must look in the same place.
        XCTAssertEqual(controller.paths.root.path, install.root.path)
        XCTAssertEqual(defaults.string(forKey: "installRoot"), install.root.path)
    }
}
