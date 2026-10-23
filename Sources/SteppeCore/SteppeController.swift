import Combine
import Foundation

public enum SetupStage: Int, CaseIterable, Identifiable, Sendable {
    case checkMac, engine, frameworks, prefix, steamClient, signIn, game
    public var id: Int { rawValue }
}

public enum StageState: Equatable, Sendable {
    case pending
    /// `progress == nil` means "working, length unknown".
    case running(progress: Double?, detail: String)
    case waitingForUser(String)
    case done
    case failed(String)
}

public enum AppPhase: Equatable, Sendable {
    case unsupported(String)
    case needsSetup
    case settingUp
    case ready
    case playing(String)
    case failed(String)
}

/// Orchestrates installation, repair and launching. All state the UI shows lives here.
@MainActor
public final class SteppeController: ObservableObject {
    // MARK: Published state
    @Published public private(set) var phase: AppPhase = .needsSetup
    @Published public private(set) var stages: [SetupStage: StageState] = Dictionary(uniqueKeysWithValues: SetupStage.allCases.map { ($0, StageState.pending) })
    @Published public var settings = AppSettings() { didSet { if settingsLoaded { saveSettings() } } }
    @Published public private(set) var paths: SteppePaths
    @Published public private(set) var systemInfo: SystemInfo
    @Published public private(set) var display: DisplayInfo?
    /// Display modes Windows reported at the last launch; `nil` until then or if the probe failed.
    @Published public private(set) var displayModes: DisplayModes?
    @Published public private(set) var freeBytes: Int64 = 0
    /// False until the first disk check has finished (it can wait on a macOS permission prompt for external disks).
    @Published public private(set) var hasCheckedDisk = false
    /// Free space still needed to finish the installation (less once the engine is in place).
    @Published public private(set) var requiredFreeBytesNow: Int64 = SteppeController.requiredFreeBytes
    @Published public private(set) var rosettaMissing = false
    @Published public private(set) var microphoneStatus: MicrophoneStatus = MicrophonePermission.status()
    @Published public private(set) var lastSessionNote: String?
    @Published public private(set) var downloadSpeed: Double = 0

    // MARK: Constants
    /// Space needed when nothing is installed yet (engine, Steam, game download and working room).
    public static let requiredFreeBytes: Int64 = 16_000_000_000
    /// Once the engine is installed only Steam and the game (about 9 GB) remain, plus working room.
    public static let requiredFreeBytesAfterEngine: Int64 = 11_000_000_000
    public static let minimumMacOS = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)

    // MARK: Private
    private let manifest = RuntimeManifest.current
    private let nativeDir: URL?
    private var setupTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var installLock: InstallLock?
    /// True while uninstalling, so nothing new can start underneath the deletion.
    private var isMaintaining = false
    private var speedSample: (time: Date, bytes: Int64)?
    private let defaults: UserDefaults
    private var settingsLoaded = false
    /// Steam needs a few seconds before its processes show up; until then it counts as running.
    private var steamLaunchGraceUntil = Date.distantPast
    private static let rootDefaultsKey = "installRoot"

    public init(nativeDir: URL?, defaults: UserDefaults = .standard, rootOverride: URL? = nil) {
        self.defaults = defaults
        self.nativeDir = nativeDir
        let root = rootOverride
            ?? defaults.string(forKey: Self.rootDefaultsKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? SteppePaths.defaultRoot()
        let paths = SteppePaths(root: root)
        self.paths = paths
        self.systemInfo = SystemInfo.detect()
        Log.shared.configure(fileURL: paths.appLogFile)
        Log.shared.info("Steppe started on \(systemInfo.chipName), macOS \(systemInfo.macOSVersion)")
    }

    // MARK: - Derived values

    public var environment: WineEnvironment { WineEnvironment(paths: paths, nativeDir: nativeDir) }
    private var steam: SteamKit { SteamKit(paths: paths, manifest: manifest) }
    private var runner: WineRunner { WineRunner(paths: paths) }

    public var plannedResolution: Resolution {
        settings.resolution(for: display?.size ?? Resolution(width: 1440, height: 900), modes: displayModes)
    }

    public var isSupportedMac: Bool { unsupportedReason == nil }

    private var unsupportedReason: String? {
        if !systemInfo.isAppleSilicon { return L("Steppe needs a Mac with Apple silicon (M1 or newer).") }
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(Self.minimumMacOS) {
            return L("Steppe needs macOS 14.6 or newer.")
        }
        return nil
    }

    // MARK: - Lifecycle

    public func handleDisplayChange() {
        display = DisplayInfo.primary()
        guard setupTask == nil, playTask == nil, !isMaintaining else { return }
        displayModes = nil
    }

    /// Re-reads everything from disk and decides which screen to show.
    public func refresh() async {
        display = DisplayInfo.primary()
        microphoneStatus = MicrophonePermission.status()
        await loadSettingsIfNeeded()
        let root = paths.root
        freeBytes = await Task.detached { SystemInfo.freeBytes(at: root) }.value
        requiredFreeBytesNow = FileManager.default.fileExists(atPath: paths.engineMarker.path)
            ? Self.requiredFreeBytesAfterEngine : Self.requiredFreeBytes
        hasCheckedDisk = true
        if let reason = unsupportedReason {
            phase = .unsupported(reason)
            return
        }
        if setupTask != nil || playTask != nil { return }
        if await isEverythingReady() {
            markAllDone()
            if await ProcessScanner.isGameRunning(inEngine: paths.wineBundle) {
                attachToRunningGame()
            } else {
                phase = .ready
            }
        } else if case .failed = phase {
            // keep the error visible until the user retries
        } else if steam.isGameInstalled {
            // The game is already here, so something else is stale (for example a newer engine ships with this
            // app version). Bring it up to date without making the user go through the welcome screen again.
            Log.shared.info("Components out of date; updating automatically")
            startSetup()
        } else {
            phase = .needsSetup
        }
    }

    /// Reads settings.json off the main thread (the first access to an external disk can wait on a system prompt).
    private func loadSettingsIfNeeded() async {
        guard !settingsLoaded else { return }
        let url = paths.settingsFile
        let loaded = await Task.detached { AppSettings.load(from: url) }.value
        settings = loaded
        settingsLoaded = true
    }

    private func isEverythingReady() async -> Bool {
        guard await engineIsReady(), frameworksAreReady(), PrefixBuilder.isHealthy(paths: paths),
              !PrefixBuilder.needsUpdate(paths: paths), steam.isClientInstalled, steam.isGameInstalled else { return false }
        return true
    }

    private func markAllDone() {
        for stage in SetupStage.allCases { stages[stage] = .done }
    }

    private func set(_ stage: SetupStage, _ state: StageState) { stages[stage] = state }

    // MARK: - Install location

    public var canChangeInstallLocation: Bool {
        !FileManager.default.fileExists(atPath: paths.engineDir.path) && setupTask == nil
    }

    public func setInstallLocation(_ url: URL) {
        guard canChangeInstallLocation else { return }
        let root = url.lastPathComponent == "Steppe" ? url : url.appendingPathComponent("Steppe", isDirectory: true)
        defaults.set(root.path, forKey: Self.rootDefaultsKey)
        paths = SteppePaths(root: root)
        settingsLoaded = false
        Log.shared.configure(fileURL: paths.appLogFile)
        hasCheckedDisk = false
        Task { await refresh() }
    }

    // MARK: - Exclusive access to the install folder

    /// Takes the cross-process lock; on failure shows an explanation and returns false.
    private func acquireLock() -> Bool {
        if installLock != nil { return true }
        guard let lock = InstallLock(root: paths.root) else {
            phase = .failed(L("Another copy of Steppe is already working with this installation."))
            return false
        }
        installLock = lock
        return true
    }

    private func releaseLockIfIdle() {
        if setupTask == nil && playTask == nil && !isMaintaining { installLock = nil }
    }

    // MARK: - Setup

    public func startSetup() {
        guard setupTask == nil, playTask == nil, !isMaintaining, isSupportedMac, acquireLock() else { return }
        phase = .settingUp
        for stage in SetupStage.allCases where stages[stage] != .done { stages[stage] = .pending }
        setupTask = Task { [weak self] in
            await self?.runSetup()
        }
    }

    public func cancelSetup() {
        setupTask?.cancel()
    }

    private func runSetup() async {
        defer {
            setupTask = nil
            releaseLockIfIdle()
        }
        do {
            try await ensureMacIsReady()
            try paths.ensureDirectories()
            try await ensureEngine()
            try await ensureFrameworks()
            try await ensurePrefix()
            try await ensureSteamClient()
            try await ensureSignInAndGame()
            await steam.shutdown(environment: environment.setup())
            phase = .ready
            lastSessionNote = nil
            Log.shared.info("Setup complete")
        } catch is CancellationError {
            Log.shared.info("Setup cancelled")
            await steam.shutdown(environment: environment.setup())
            phase = .needsSetup
        } catch {
            Log.shared.error("Setup failed: \(error.localizedDescription)")
            failCurrentStage(error.localizedDescription)
            phase = .failed(error.localizedDescription)
        }
    }

    private func failCurrentStage(_ message: String) {
        for stage in SetupStage.allCases {
            switch stages[stage] {
            case .running, .waitingForUser: stages[stage] = .failed(message)
            default: continue
            }
        }
    }

    // MARK: Stage: Mac

    private func ensureMacIsReady() async throws {
        set(.checkMac, .running(progress: nil, detail: L("Checking your Mac")))
        freeBytes = SystemInfo.freeBytes(at: paths.root)
        let alreadyInstalled = await engineIsReady()
        let needed = alreadyInstalled ? Self.requiredFreeBytesAfterEngine : Self.requiredFreeBytes
        if !steam.isGameInstalled && freeBytes < needed {
            throw SetupError.notEnoughSpace(needed: needed, available: freeBytes)
        }
        if !(await SystemInfo.rosettaInstalled()) {
            rosettaMissing = true
            set(.checkMac, .waitingForUser(L("Rosetta 2 is required")))
            while !(await SystemInfo.rosettaInstalled()) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            rosettaMissing = false
        }
        set(.checkMac, .done)
    }

    /// Installs Rosetta 2 through the standard macOS administrator prompt.
    public func installRosetta() {
        Task {
            let script = #"do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges"#
            _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script], timeout: 900)
            rosettaMissing = !(await SystemInfo.rosettaInstalled())
        }
    }

    // MARK: Stage: engine

    private func engineIsReady() async -> Bool {
        guard let marker = ComponentMarker.read(paths.engineMarker),
              marker.checksum == manifest.engine.sha256,
              marker.patchRevision == manifest.patchRevision,
              FileManager.default.isExecutableFile(atPath: paths.wineBinary.path) else { return false }
        return await WinePatcher.isPatched(engineRoot: paths.wineBundle, patch: manifest.winemac)
    }

    private func ensureEngine() async throws {
        if await engineIsReady() { set(.engine, .done); return }
        let fm = FileManager.default
        let archive = paths.downloadsDir.appendingPathComponent("engine.tar.xz")
        try await download(manifest.engine, to: archive, stage: .engine, label: L("Downloading the Wine engine"), share: 0.8)

        set(.engine, .running(progress: nil, detail: L("Unpacking")))
        let staging = paths.root.appendingPathComponent("engine.tmp", isDirectory: true)
        try? fm.removeItem(at: staging)
        try await Archive.extract(archive, to: staging)
        let bundle = staging.appendingPathComponent(manifest.engineArchiveRoot, isDirectory: true)
        guard fm.isExecutableFile(atPath: bundle.appendingPathComponent("bin/wine").path) else {
            try? fm.removeItem(at: staging)
            throw SetupError.engineLayout
        }

        set(.engine, .running(progress: nil, detail: L("Applying macOS fixes")))
        try await WinePatcher.apply(engineRoot: bundle, patch: manifest.winemac)

        try? fm.removeItem(at: paths.engineDir)
        try fm.moveItem(at: staging, to: paths.engineDir)
        try ComponentMarker(name: manifest.engine.name, checksum: manifest.engine.sha256, patchRevision: manifest.patchRevision)
            .write(paths.engineMarker)
        try? fm.removeItem(at: archive)
        set(.engine, .done)
    }

    // MARK: Stage: frameworks

    private func frameworksAreReady() -> Bool {
        guard let marker = ComponentMarker.read(paths.frameworksMarker), marker.checksum == manifest.template.sha256 else { return false }
        return FileManager.default.fileExists(atPath: paths.frameworksDir.appendingPathComponent("libfreetype.6.dylib").path)
    }

    private func ensureFrameworks() async throws {
        if frameworksAreReady() { set(.frameworks, .done); return }
        let fm = FileManager.default
        let archive = paths.downloadsDir.appendingPathComponent("frameworks.tar.xz")
        try await download(manifest.template, to: archive, stage: .frameworks, label: L("Downloading graphics libraries"), share: 0.8)

        set(.frameworks, .running(progress: nil, detail: L("Unpacking")))
        let staging = paths.root.appendingPathComponent("frameworks.tmp", isDirectory: true)
        try? fm.removeItem(at: staging)
        try await Archive.extract(archive, to: staging, members: [manifest.templateFrameworksPath])
        let extracted = staging.appendingPathComponent(manifest.templateFrameworksPath, isDirectory: true)
        guard fm.fileExists(atPath: extracted.appendingPathComponent("libfreetype.6.dylib").path) else {
            try? fm.removeItem(at: staging)
            throw SetupError.engineLayout
        }
        try? fm.removeItem(at: paths.frameworksDir)
        try fm.moveItem(at: extracted, to: paths.frameworksDir)
        try? fm.removeItem(at: staging)
        try ComponentMarker(name: manifest.template.name, checksum: manifest.template.sha256, patchRevision: manifest.patchRevision)
            .write(paths.frameworksMarker)
        try? fm.removeItem(at: archive)
        set(.frameworks, .done)
    }

    // MARK: Stage: prefix

    private func ensurePrefix() async throws {
        if PrefixBuilder.isHealthy(paths: paths) {
            if PrefixBuilder.needsUpdate(paths: paths) {
                set(.prefix, .running(progress: nil, detail: L("Updating the Windows environment")))
                try await PrefixBuilder.update(runner: runner, environment: environment.setup())
            } else {
                PrefixBuilder.isolatePrefixQuietly(paths.prefixDir)
            }
            set(.prefix, .done)
            return
        }
        set(.prefix, .running(progress: nil, detail: L("Creating the Windows environment")))
        try await PrefixBuilder.create(runner: runner, environment: environment.setup())
        set(.prefix, .done)
    }

    // MARK: Stage: Steam client

    private func ensureSteamClient() async throws {
        if steam.isClientInstalled { set(.steamClient, .done); return }
        set(.steamClient, .running(progress: 0, detail: L("Downloading Steam")))
        let kit = steam
        let env = environment.setup()
        let report: @Sendable (DownloadProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.set(.steamClient, .running(progress: p.fraction * 0.5, detail: L("Downloading Steam"))) }
        }
        try await kit.installClient(environment: env, progress: report)
        PrefixBuilder.isolatePrefixQuietly(paths.prefixDir)
        set(.steamClient, .done)
    }

    // MARK: Stage: sign-in + game download

    /// Ensures the Wine engine binaries carry audio-input entitlements and macOS TCC microphone permission
    /// is settled before Steam initializes CoreAudio (`winecoreaudio.drv`).
    private func prepareMicrophoneAndEngineForSteam() async {
        await WinePatcher.ensureAudioEntitlements(engineRoot: paths.wineBundle)
        microphoneStatus = await MicrophonePermission.ensureAccessForSteam(defaults: defaults)
    }

    public func requestMicrophoneAccess() {
        Task {
            microphoneStatus = await MicrophonePermission.ensureAccessForSteam(defaults: defaults)
        }
    }

    public func resetMicrophoneAccess() {
        Task {
            microphoneStatus = await MicrophonePermission.resetAndRequestAccess(defaults: defaults)
        }
    }

    /// Opens Steam so the user can sign in (also used by the "Open Steam" button).
    public func openSteam() {
        Task {
            guard !(await steam.isClientRunning()) else { return }
            await prepareMicrophoneAndEngineForSteam()
            steamLaunchGraceUntil = Date().addingTimeInterval(25)
            _ = try? steam.launchClient(environment: environment.setup(), logName: "steam-setup.log")
        }
    }

    private func ensureSignInAndGame() async throws {
        let kit = steam
        if kit.isGameInstalled { set(.signIn, .done); set(.game, .done); return }

        let env = environment.setup()
        if !(await kit.isClientRunning()) {
            set(.signIn, .running(progress: nil, detail: L("Starting Steam")))
            await prepareMicrophoneAndEngineForSteam()
            steamLaunchGraceUntil = Date().addingTimeInterval(25)
            try kit.launchClient(environment: env, logName: "steam-setup.log")
        }

        var installRequestedAt: Date?
        var announcedSignIn = false
        while true {
            try Task.checkCancellation()
            if kit.isGameInstalled { break }

            let steamUp = await kit.isClientRunning() || Date() < steamLaunchGraceUntil
            if kit.appManifest != nil, !steamUp {
                // Steam was closed in the middle of the download; ask the user to open it again.
                set(.signIn, .done)
                set(.game, .waitingForUser(L("Steam is not running — open it to continue")))
            } else if let info = kit.appManifest {
                set(.signIn, .done)
                if let fraction = info.downloadFraction {
                    let done = ByteCountFormatter.string(fromByteCount: info.bytesDownloaded, countStyle: .file)
                    let total = ByteCountFormatter.string(fromByteCount: info.bytesToDownload, countStyle: .file)
                    set(.game, .running(progress: fraction, detail: L("Steam is downloading Cossacks 3 — %@ of %@", done, total)))
                } else {
                    set(.game, .running(progress: nil, detail: L("Steam is preparing the download")))
                }
            } else if kit.hasSignedIn {
                set(.signIn, .done)
                if installRequestedAt == nil || Date().timeIntervalSince(installRequestedAt!) > 90 {
                    try kit.requestGameInstall(environment: env)
                    installRequestedAt = Date()
                }
                set(.game, .waitingForUser(L("Click Install in the Steam window")))
            } else {
                if !announcedSignIn {
                    announcedSignIn = true
                    Log.shared.info("Waiting for the user to sign in to Steam")
                }
                if await kit.isClientRunning() || Date() < steamLaunchGraceUntil {
                    set(.signIn, .waitingForUser(L("Sign in to Steam in the window that opened")))
                } else {
                    set(.signIn, .waitingForUser(L("Steam is not running — open it to continue")))
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        set(.signIn, .done)
        set(.game, .done)
    }

    // MARK: Download helper

    private func download(_ item: RuntimeManifest.Download, to destination: URL, stage: SetupStage, label: String, share: Double) async throws {
        speedSample = nil
        set(stage, .running(progress: 0, detail: label))
        try await Downloader.download(url: item.url, to: destination, expectedSHA256: item.sha256, expectedSize: item.sizeBytes) { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                self.updateSpeed(bytes: p.received)
                let received = ByteCountFormatter.string(fromByteCount: p.received, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
                self.set(stage, .running(progress: p.fraction * share, detail: L("%@ — %@ of %@", label, received, total)))
            }
        }
    }

    private func updateSpeed(bytes: Int64) {
        let now = Date()
        if let sample = speedSample {
            let dt = now.timeIntervalSince(sample.time)
            if dt >= 1 {
                downloadSpeed = Double(bytes - sample.bytes) / dt
                speedSample = (now, bytes)
            }
        } else {
            speedSample = (now, bytes)
        }
    }

    // MARK: - Playing

    public func play() {
        guard case .ready = phase, playTask == nil, !isMaintaining, acquireLock() else { return }
        phase = .playing(L("Preparing"))
        playTask = Task { [weak self] in
            await self?.runPlay()
        }
    }

    private func runPlay() async {
        defer {
            playTask = nil
            releaseLockIfIdle()
        }
        let kit = steam
        do {
            // Steam must be restarted so the graphics fixes are injected into it and the game.
            if await runner.isAnyProcessRunning() {
                phase = .playing(L("Restarting Steam"))
                await kit.shutdown(environment: environment.setup())
            }
            try PrefixBuilder.isolate(prefix: paths.prefixDir)

            display = DisplayInfo.primary()
            phase = .playing(L("Preparing"))
            displayModes = await probeDisplayModes()
            let resolution = plannedResolution
            if let modes = displayModes {
                Log.shared.info("Windows monitor \(modes.current), \(modes.all.count) modes; planned \(settings.resolution(for: modes.current)), writing \(resolution)")
            }
            seedFirstRunFiles(resolution)
            applyTuning(resolution)
            let speedStatus = installSpeedLibraries()

            try? FileManager.default.createDirectory(at: paths.patchLogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: paths.patchLogFile)
            phase = .playing(L("Starting Steam"))
            await prepareMicrophoneAndEngineForSteam()
            try kit.launchClient(arguments: ["-applaunch", String(manifest.steam.appID)], environment: environment.game(settings: settings), logName: "game-session.log")
            Log.shared.info("Launched at \(resolution); speed libraries: \(speedStatus)")
            startDialogHelper()

            var waited = 0
            while !(await ProcessScanner.isGameRunning(inEngine: paths.wineBundle)) {
                try Task.checkCancellation()
                waited += 2
                if waited > 600 { throw SetupError.gameDidNotStart }
                if waited > 30 { phase = .playing(L("Waiting for Steam — sign in there if it asks")) }
                else if waited > 8 { phase = .playing(L("Launching Cossacks 3")) }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            phase = .playing(L("Running"))
            let runStarted = Date()
            while await ProcessScanner.isGameRunning(inEngine: paths.wineBundle) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            let runDuration = Date().timeIntervalSince(runStarted)
            await finishSession(resolution: resolution, runDuration: runDuration)
        } catch {
            Log.shared.error("Play failed: \(error.localizedDescription)")
            await steam.shutdown(environment: environment.setup())
            lastSessionNote = error.localizedDescription
            phase = .ready
        }
    }

    private func attachToRunningGame() {
        guard playTask == nil else { return }
        phase = .playing(L("Running"))
        playTask = Task { [weak self] in
            guard let self else { return }
            defer { self.playTask = nil }
            while await ProcessScanner.isGameRunning(inEngine: self.paths.wineBundle) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await self.finishSession(resolution: self.plannedResolution)
        }
    }

    private func finishSession(resolution: Resolution, runDuration: TimeInterval? = nil) async {
        // A profile created during this session only now has a profile.cfg.
        applyTuning(resolution)
        if settings.quitSteamAfterGame {
            phase = .playing(L("Saving to Steam Cloud"))
            await steam.shutdown(environment: environment.setup())
        }
        if let runDuration {
            let sessionLogURL = paths.logsDir.appendingPathComponent("game-session.log")
            let logText = (try? Data(contentsOf: sessionLogURL)).flatMap { String(data: $0, encoding: .isoLatin1) } ?? ""
            let outcome = LaunchOutcome.classify(duration: runDuration, logTail: String(logText.suffix(16_384)), resolution: resolution)
            if let note = outcome.userNote {
                Log.shared.warn("Early game exit (\(Int(runDuration))s): \(outcome)")
                lastSessionNote = note
            } else {
                lastSessionNote = nil
            }
        } else {
            lastSessionNote = nil
        }
        phase = .ready
    }

    /// Writes the files the game needs on a fresh install (see `GameBootstrap`); existing files are left alone.
    private func seedFirstRunFiles(_ resolution: Resolution) {
        guard let userDir = paths.windowsUserDir, let gameDir = steam.gameDirectory else { return }
        let locales = ((try? FileManager.default.contentsOfDirectory(atPath: gameDir.appendingPathComponent("data/locale").path)) ?? [])
        let language = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        let loginUsers = paths.steamDir.appendingPathComponent("config/loginusers.vdf")
        let persona = (try? String(contentsOf: loginUsers, encoding: .utf8)).flatMap(GameBootstrap.personaName(fromLoginUsers:))
        do {
            let created = try GameBootstrap.seed(
                documentsGameDir: userDir.appendingPathComponent("Documents/cossacks", isDirectory: true),
                profileName: GameBootstrap.sanitizedProfileName(persona),
                locale: GameBootstrap.localeFolder(languageCode: language, available: locales),
                resolution: resolution
            )
            if !created.isEmpty { Log.shared.info("First-run files created: \(created.count)") }
        } catch {
            Log.shared.warn("Could not create first-run files: \(error.localizedDescription)")
        }
    }

    private func applyTuning(_ resolution: Resolution) {
        guard let dir = paths.gameProfilesDir else { return }
        do {
            let outcome = try ProfileTuner.apply(resolution: resolution, profilesDir: dir)
            Log.shared.info("Profile tuning: updated \(outcome.updated.count), unchanged \(outcome.unchanged.count), skipped \(outcome.skipped.count)")
        } catch {
            Log.shared.warn("Profile tuning failed: \(error.localizedDescription)")
        }
    }

    /// Starts the tiny in-prefix helper that presses OK on the game's informational "hardware acceleration" box.
    private func startDialogHelper() {
        guard installTool("dismiss-dialog.exe") else {
            Log.shared.warn("dismiss-dialog.exe missing; the startup box will need one click")
            return
        }
        do {
            try runner.spawn([SteppePaths.dialogHelperWindowsPath, "600"], environment: environment.game(settings: settings), logName: "dialog-helper.log")
        } catch {
            Log.shared.warn("Could not start the dialog helper: \(error.localizedDescription)")
        }
    }

    /// Asks Windows inside the prefix which display modes exist (`list-modes.exe`). `nil` if the helper is missing or fails.
    private func probeDisplayModes() async -> DisplayModes? {
        guard installTool("list-modes.exe") else {
            Log.shared.warn("list-modes.exe missing; the resolution is not checked against Windows display modes")
            return nil
        }
        do {
            let result = try await runner.run([SteppePaths.listModesWindowsPath], environment: environment.game(settings: settings), timeout: 60)
            guard let modes = DisplayModes.parse(result.stdout) else {
                Log.shared.warn("list-modes.exe reported no display modes (exit \(result.exitCode))")
                return nil
            }
            return modes
        } catch {
            Log.shared.warn("Could not list display modes: \(error.localizedDescription)")
            return nil
        }
    }

    /// Copies a helper program from the app bundle into the prefix's tools folder. False if it is not bundled or cannot be copied.
    private func installTool(_ name: String) -> Bool {
        guard let nativeDir else { return false }
        let source = nativeDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: paths.toolsDir, withIntermediateDirectories: true)
            let target = paths.toolsDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            return true
        } catch {
            Log.shared.warn("Could not copy \(name) into the prefix: \(error.localizedDescription)")
            return false
        }
    }

    /// What the speed-patch library reported during the current or last session.
    public var patchReport: PatchReport {
        PatchReport.parse((try? String(contentsOf: paths.patchLogFile, encoding: .utf8)) ?? "")
    }

    private func installSpeedLibraries() -> [GameFiles.Status] {
        guard let nativeDir, let gameDir = steam.gameDirectory else { return [] }
        return GameFiles.installSpeedLibraries(from: nativeDir, into: gameDir, knownOriginals: manifest.originalGameDLLs)
    }

    /// Force-closes the game, Steam and every Wine process of the prefix.
    public func forceStop() {
        playTask?.cancel()
        Task {
            await runner.killAll(environment: environment.setup())
            await refresh()
        }
    }

    // MARK: - Maintenance

    /// Re-checks every component and fixes what is missing or damaged.
    public func repair() {
        guard setupTask == nil, playTask == nil, !isMaintaining else { return }
        if let gameDir = steam.gameDirectory { _ = GameFiles.restoreOriginals(in: gameDir) }
        // Dropping the markers makes the setup flow re-verify and rebuild each component.
        try? FileManager.default.removeItem(at: paths.engineMarker)
        try? FileManager.default.removeItem(at: paths.frameworksMarker)
        Task {
            await MicrophonePermission.resetTCC()
            self.microphoneStatus = MicrophonePermission.status()
        }
        for stage in SetupStage.allCases { stages[stage] = .pending }
        startSetup()
    }

    /// Deletes everything Steppe installed (engine, Windows environment, Steam, game, logs).
    public func uninstall() async {
        guard !isMaintaining else { return }
        isMaintaining = true
        let setup = setupTask, play = playTask
        setup?.cancel()
        play?.cancel()
        await setup?.value
        await play?.value
        guard acquireLock() else { isMaintaining = false; return }
        await runner.killAll(environment: environment.setup())
        try? FileManager.default.removeItem(at: paths.root)
        defaults.removeObject(forKey: Self.rootDefaultsKey)
        installLock = nil
        isMaintaining = false
        for stage in SetupStage.allCases { stages[stage] = .pending }
        settingsLoaded = false
        phase = .needsSetup
        await refresh()
    }

    public func exportDiagnostics() throws -> URL {
        try Diagnostics.export(controller: self)
    }

    // MARK: - Settings persistence

    private func saveSettings() {
        do { try settings.save(to: paths.settingsFile) } catch {
            Log.shared.warn("Could not save settings: \(error.localizedDescription)")
        }
    }

    // MARK: - Information for the diagnostics report

    var diagnosticsSnapshot: DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            system: systemInfo,
            display: display,
            displayModes: displayModes,
            resolution: plannedResolution,
            settings: settings,
            microphoneStatus: microphoneStatus,
            stageSummary: SetupStage.allCases.map { "\($0): \(String(describing: stages[$0] ?? .pending))" },
            phase: String(describing: phase),
            freeBytes: freeBytes,
            gameManifest: steam.appManifest,
            paths: paths,
            leaks: PrefixBuilder.escapesPrefix(prefix: paths.prefixDir)
        )
    }
}

public enum SetupError: Error, LocalizedError {
    case notEnoughSpace(needed: Int64, available: Int64)
    case engineLayout
    case gameDidNotStart

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let a = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return L("Not enough free disk space: %@ needed, %@ available. Free up space or choose another disk.", n, a)
        case .engineLayout: return L("The downloaded files were not laid out as expected. Try again.")
        case .gameDidNotStart: return L("Cossacks 3 did not start. Check the Steam window for a prompt and try again.")
        }
    }
}
