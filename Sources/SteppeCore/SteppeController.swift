import Combine
import Darwin
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

public enum SetupUserPrompt: Equatable, Sendable {
    case installRosetta
    case signInSteam
    case steamClosedReopen
    case installGame
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
    @Published public private(set) var activePrompt: SetupUserPrompt?
    @Published public var settings = AppSettings() { didSet { if settingsLoaded { saveSettings() } } }
    @Published public private(set) var paths: SteppePaths
    @Published public private(set) var systemInfo: SystemInfo
    @Published public private(set) var display: DisplayInfo?
    /// Display modes Windows reported at the last launch; `nil` until then or if the probe failed.
    @Published public private(set) var displayModes: DisplayModes?
    @Published public private(set) var diskStatus: SystemInfo.DiskStatus = .available(0)
    @Published public private(set) var freeBytes: Int64 = 0
    /// False until the first disk check has finished (it can wait on a macOS permission prompt for external disks).
    @Published public private(set) var hasCheckedDisk = false
    /// Free space still needed to finish the installation (less once the engine is in place).
    @Published public private(set) var requiredFreeBytesNow: Int64 = SteppeController.requiredFreeBytes
    @Published public private(set) var rosettaMissing = false
    @Published public private(set) var microphoneStatus: MicrophoneStatus
    @Published public private(set) var lastSessionNote: String?
    @Published public private(set) var downloadSpeed: Double = 0
    /// True while repairing or uninstalling so destructive/concurrent actions wait.
    @Published public private(set) var isMaintaining = false
    /// Cached asynchronously from `patchLogFile` so UI body renders never perform blocking disk reads.
    @Published public private(set) var cachedPatchReport: PatchReport = .empty

    // MARK: Constants
    /// Space needed when nothing is installed yet (engine, Steam, game download and working room).
    public static let requiredFreeBytes: Int64 = 16_000_000_000
    /// Once the engine is installed only Steam and the game (about 9 GB) remain, plus working room.
    public static let requiredFreeBytesAfterEngine: Int64 = 11_000_000_000
    public static let minimumMacOS = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)
    private static let maxFrameTimesArchiveBytes: Int64 = 20 * 1024 * 1024

    // MARK: Private
    private let manifest: RuntimeManifest
    private let nativeDir: URL?
    private let runtime: any SteppeRuntime
    private let pollIntervalNanoseconds: UInt64
    private let configureGlobalLogger: Bool
    private var setupTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var installLock: InstallLock?
    private var speedSample: (time: Date, bytes: Int64)?
    private let defaults: UserDefaults
    private var settingsLoaded = false
    private var operationGeneration: UInt64 = 0
    private var autoSetupSuppressed = false
    private var forcePrefixRepair = false
    /// Steam needs a few seconds before its processes show up; until then it counts as running.
    private var steamLaunchGraceUntil = Date.distantPast
    private let rootOverride: URL?
    private static let rootDefaultsKey = "installRoot"

    public init(
        nativeDir: URL?,
        defaults: UserDefaults = .standard,
        rootOverride: URL? = nil,
        profile: GameProfile = .cossacks3,
        manifest: RuntimeManifest = .current,
        runtime: any SteppeRuntime = LiveSteppeRuntime(),
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        configureGlobalLogger: Bool = true
    ) {
        self.defaults = defaults
        self.nativeDir = nativeDir
        self.rootOverride = rootOverride
        self.manifest = manifest
        self.runtime = runtime
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.configureGlobalLogger = configureGlobalLogger
        let root = rootOverride
            ?? defaults.string(forKey: Self.rootDefaultsKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? SteppePaths.defaultRoot()
        let paths = SteppePaths(root: root, profile: profile)
        self.paths = paths
        self.systemInfo = SystemInfo.detect()
        self.microphoneStatus = runtime.microphoneStatus()
        if configureGlobalLogger {
            Log.shared.configure(fileURL: paths.appLogFile)
        }
        Log.shared.info("Steppe started on \(systemInfo.chipName), macOS \(systemInfo.macOSVersion)")
    }

    // MARK: - Derived values

    public var isBusy: Bool { setupTask != nil || playTask != nil || isMaintaining }
    public var environment: WineEnvironment { WineEnvironment(paths: paths, nativeDir: nativeDir) }
    public var patchReport: PatchReport { cachedPatchReport }
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
        display = runtime.primaryDisplay()
        guard setupTask == nil, playTask == nil, !isMaintaining else { return }
        displayModes = nil
    }

    /// Re-reads everything from disk and decides which screen to show.
    public func refresh(allowAutoSetup: Bool = true) async {
        let gen = operationGeneration
        display = runtime.primaryDisplay()
        microphoneStatus = runtime.microphoneStatus()
        await loadSettingsIfNeeded()
        guard gen == operationGeneration else { return }

        let root = paths.root
        let status = await runtime.diskStatus(at: root)
        guard gen == operationGeneration else { return }
        applyDiskStatus(status)
        requiredFreeBytesNow = FileManager.default.fileExists(atPath: paths.engineMarker.path)
            ? Self.requiredFreeBytesAfterEngine : Self.requiredFreeBytes
        hasCheckedDisk = true

        await reloadPatchReport()
        guard gen == operationGeneration else { return }

        if let reason = unsupportedReason {
            phase = .unsupported(reason)
            return
        }
        if setupTask != nil || playTask != nil || isMaintaining { return }

        let ready = await isEverythingReady()
        guard gen == operationGeneration, setupTask == nil, playTask == nil, !isMaintaining else { return }

        if ready {
            markAllDone()
            switch await runtime.checkGameRunning(inEngine: paths.wineBundle, executableName: paths.profile.executableName) {
            case .running:
                guard gen == operationGeneration, setupTask == nil, playTask == nil, !isMaintaining else { return }
                attachToRunningGame()
            case .notRunning:
                guard gen == operationGeneration, setupTask == nil, playTask == nil, !isMaintaining else { return }
                phase = .ready
            case .unknown(let reason):
                guard gen == operationGeneration, setupTask == nil, playTask == nil, !isMaintaining else { return }
                Log.shared.warn("Process scan failed during refresh: \(reason)")
                phase = .ready
            }
        } else if case .failed = phase {
            // keep the error visible until the user retries
        } else if allowAutoSetup && !autoSetupSuppressed && steam.isGameInstalled {
            // The game is already here, so something else is stale (for example a newer engine ships with this
            // app version). Bring it up to date without making the user go through the welcome screen again.
            Log.shared.info("Components out of date; updating automatically")
            startSetup()
        } else {
            phase = .needsSetup
        }
    }

    private func applyDiskStatus(_ status: SystemInfo.DiskStatus) {
        diskStatus = status
        if case .available(let bytes) = status {
            freeBytes = bytes
        } else {
            freeBytes = 0
        }
    }

    /// Loads `settings.json` off the main thread without re-triggering `saveSettings()`.
    private func loadSettingsIfNeeded() async {
        guard !settingsLoaded else { return }
        let gen = operationGeneration
        let url = paths.settingsFile
        let loaded = await Task.detached { AppSettings.load(from: url) }.value
        guard gen == operationGeneration, url == paths.settingsFile else { return }
        settings = loaded
        settingsLoaded = true
    }

    public func reloadPatchReport() async {
        let gen = operationGeneration
        let logURL = paths.patchLogFile
        let report = await Task.detached {
            let text = (try? Data(contentsOf: logURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return PatchReport.parse(text)
        }.value
        guard gen == operationGeneration, logURL == paths.patchLogFile else { return }
        cachedPatchReport = report
    }

    private func isEverythingReady() async -> Bool {
        guard await engineIsReady(), frameworksAreReady(), PrefixBuilder.isHealthy(paths: paths),
              !PrefixBuilder.needsUpdate(paths: paths), steam.isClientInstalled, steam.isGameInstalled else { return false }
        return true
    }

    private func markAllDone() {
        for stage in SetupStage.allCases { stages[stage] = .done }
    }

    private func set(_ stage: SetupStage, _ state: StageState) {
        stages[stage] = state
        if case .running = state { activePrompt = nil }
        if case .done = state { activePrompt = nil }
        if case .failed = state { activePrompt = nil }
    }

    // MARK: - Install location

    public var canChangeInstallLocation: Bool {
        !FileManager.default.fileExists(atPath: paths.engineDir.path) && !isBusy
    }

    public func setInstallLocation(_ url: URL) {
        guard canChangeInstallLocation else { return }
        operationGeneration &+= 1
        let root = url.lastPathComponent == "Steppe" ? url : url.appendingPathComponent("Steppe", isDirectory: true)
        defaults.set(root.path, forKey: Self.rootDefaultsKey)
        paths = SteppePaths(root: root, profile: paths.profile)
        displayModes = nil
        cachedPatchReport = .empty
        settingsLoaded = false
        autoSetupSuppressed = false
        if configureGlobalLogger {
            Log.shared.configure(fileURL: paths.appLogFile)
        }
        hasCheckedDisk = false
        Task { await refresh() }
    }

    // MARK: - Exclusive access to the install folder

    /// Takes the cross-process lock; on failure surfaces a specific explanation and returns false.
    private func acquireLock(forPlay: Bool) -> Bool {
        if installLock != nil { return true }
        switch runtime.acquireLock(root: paths.root) {
        case .success(let lock):
            installLock = lock
            return true
        case .failure(.alreadyHeld):
            let message = L("Another copy of Steppe is already working with this installation.")
            if forPlay { lastSessionNote = message } else { phase = .failed(message) }
            return false
        case .failure(.ioError(let code)):
            let posix = String(cString: strerror(code))
            let message = L("Could not access the installation folder (%@).", posix)
            if forPlay { lastSessionNote = message } else { phase = .failed(message) }
            return false
        case .failure(.directoryError(let reason)):
            let message = L("Could not access the installation folder (%@).", reason)
            if forPlay { lastSessionNote = message } else { phase = .failed(message) }
            return false
        }
    }

    private func releaseLockIfIdle() {
        if setupTask == nil && playTask == nil && !isMaintaining { installLock = nil }
    }

    // MARK: - Setup

    public func startSetup() {
        autoSetupSuppressed = false
        guard setupTask == nil, playTask == nil, !isMaintaining, isSupportedMac else { return }
        operationGeneration &+= 1
        activePrompt = nil
        phase = .settingUp
        for stage in SetupStage.allCases where stages[stage] != .done { stages[stage] = .pending }
        setupTask = Task { [weak self] in
            await self?.runSetup()
        }
    }

    public func cancelSetup() {
        autoSetupSuppressed = true
        activePrompt = nil
        setupTask?.cancel()
    }

    private func runSetup() async {
        defer {
            setupTask = nil
            forcePrefixRepair = false
            activePrompt = nil
            releaseLockIfIdle()
        }
        do {
            set(.checkMac, .running(progress: nil, detail: L("Checking your Mac")))
            let disk = await runtime.diskStatus(at: paths.root)
            applyDiskStatus(disk)
            if case .externalVolumeUnmounted(let volumeName) = disk {
                throw SetupError.externalDriveNotConnected(volumeName)
            }
            guard acquireLock(forPlay: false) else {
                if case .failed(let message) = phase { failCurrentStage(message) }
                return
            }
            if forcePrefixRepair {
                if let gameDir = steam.gameDirectory { _ = GameFiles.restoreOriginals(in: gameDir) }
                try? FileManager.default.removeItem(at: paths.engineMarker)
                try? FileManager.default.removeItem(at: paths.frameworksMarker)
            }
            try await ensureMacIsReady(prefetchedDiskStatus: disk)
            try paths.ensureDirectories()
            try await ensureEngine()
            try await ensureFrameworks()
            try await ensurePrefix()
            try await ensureSteamClient()
            try await ensureSignInAndGame()
            await runtime.shutdownSteam(paths: paths, manifest: manifest, environment: environment.setup())
            phase = .ready
            lastSessionNote = nil
            Log.shared.info("Setup complete")
        } catch is CancellationError {
            Log.shared.info("Setup cancelled")
            await runtime.shutdownSteam(paths: paths, manifest: manifest, environment: environment.setup())
            phase = .needsSetup
        } catch {
            Log.shared.error("Setup failed: \(error.localizedDescription)")
            failCurrentStage(error.localizedDescription)
            phase = .failed(error.localizedDescription)
        }
    }

    private func failCurrentStage(_ message: String) {
        activePrompt = nil
        for stage in SetupStage.allCases {
            switch stages[stage] {
            case .running, .waitingForUser: stages[stage] = .failed(message)
            default: continue
            }
        }
    }

    // MARK: Stage: Mac

    private func ensureMacIsReady(prefetchedDiskStatus: SystemInfo.DiskStatus? = nil) async throws {
        set(.checkMac, .running(progress: nil, detail: L("Checking your Mac")))
        let status: SystemInfo.DiskStatus
        if let prefetchedDiskStatus {
            status = prefetchedDiskStatus
        } else {
            status = await runtime.diskStatus(at: paths.root)
            applyDiskStatus(status)
        }
        if case .externalVolumeUnmounted(let volumeName) = status {
            throw SetupError.externalDriveNotConnected(volumeName)
        }
        let alreadyInstalled = await engineIsReady()
        let needed = alreadyInstalled ? Self.requiredFreeBytesAfterEngine : Self.requiredFreeBytes
        if !steam.isGameInstalled && freeBytes < needed {
            throw SetupError.notEnoughSpace(needed: needed, available: freeBytes)
        }
        if !(await runtime.isRosettaInstalled()) {
            rosettaMissing = true
            activePrompt = .installRosetta
            set(.checkMac, .waitingForUser(L("Rosetta 2 is required")))
            while !(await runtime.isRosettaInstalled()) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
            rosettaMissing = false
            activePrompt = nil
        }
        set(.checkMac, .done)
    }

    /// Installs Rosetta 2 through the standard macOS administrator prompt.
    public func installRosetta() {
        let gen = operationGeneration
        Task {
            let script = #"do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges"#
            _ = await runtime.runProcess(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script], timeout: 900)
            let installed = await runtime.isRosettaInstalled()
            guard gen == operationGeneration else { return }
            rosettaMissing = !installed
        }
    }

    // MARK: Stage: engine

    private func engineIsReady() async -> Bool {
        guard let marker = ComponentMarker.read(paths.engineMarker),
              marker.checksum == manifest.engine.sha256,
              marker.patchRevision == manifest.patchRevision,
              FileManager.default.isExecutableFile(atPath: paths.wineBinary.path) else { return false }
        return await runtime.isEnginePatched(bundle: paths.wineBundle, patch: manifest.winemac)
    }

    private func ensureEngine() async throws {
        if await engineIsReady() { set(.engine, .done); return }
        let fm = FileManager.default
        let archive = paths.downloadsDir.appendingPathComponent("engine.tar.xz")
        try await download(manifest.engine, to: archive, stage: .engine, label: L("Downloading the Wine engine"), share: 0.8)

        set(.engine, .running(progress: nil, detail: L("Unpacking")))
        let staging = paths.root.appendingPathComponent("engine.tmp", isDirectory: true)
        try? fm.removeItem(at: staging)
        try await runtime.extractArchive(archive, to: staging, members: nil)
        let bundle = staging.appendingPathComponent(manifest.engineArchiveRoot, isDirectory: true)
        guard fm.isExecutableFile(atPath: bundle.appendingPathComponent("bin/wine").path) else {
            try? fm.removeItem(at: staging)
            throw SetupError.engineLayout
        }

        set(.engine, .running(progress: nil, detail: L("Applying macOS fixes")))
        try await runtime.patchEngine(bundle: bundle, patch: manifest.winemac)

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
        try await runtime.extractArchive(archive, to: staging, members: [manifest.templateFrameworksPath])
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
        let shouldForceRepair = forcePrefixRepair
        forcePrefixRepair = false
        if PrefixBuilder.isHealthy(paths: paths) {
            if shouldForceRepair || PrefixBuilder.needsUpdate(paths: paths) {
                set(.prefix, .running(progress: nil, detail: L("Updating the Windows environment")))
                try await runtime.updatePrefix(paths: paths, environment: environment.setup())
            } else {
                PrefixBuilder.isolatePrefixQuietly(paths.prefixDir)
            }
            set(.prefix, .done)
            return
        }
        set(.prefix, .running(progress: nil, detail: L("Creating the Windows environment")))
        try await runtime.createPrefix(paths: paths, environment: environment.setup())
        set(.prefix, .done)
    }

    // MARK: Stage: Steam client

    private func ensureSteamClient() async throws {
        if steam.isClientInstalled { set(.steamClient, .done); return }
        set(.steamClient, .running(progress: 0, detail: L("Downloading Steam")))
        let env = environment.setup()
        let report: @Sendable (DownloadProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.set(.steamClient, .running(progress: p.fraction * 0.5, detail: L("Downloading Steam"))) }
        }
        try await runtime.installSteamClient(paths: paths, manifest: manifest, environment: env, progress: report)
        PrefixBuilder.isolatePrefixQuietly(paths.prefixDir)
        set(.steamClient, .done)
    }

    // MARK: Stage: sign-in + game download

    /// Ensures the Wine engine binaries carry entitlements and checks/requests macOS TCC microphone access only if enabled.
    private func prepareEngineAndMicrophoneForSteam() async {
        await runtime.ensureAudioEntitlements(engineRoot: paths.wineBundle)
        if settings.enableMicrophone {
            microphoneStatus = await runtime.ensureMicrophoneAccess(defaults: defaults)
        } else {
            microphoneStatus = runtime.microphoneStatus()
        }
    }

    public func requestMicrophoneAccess() {
        settings.enableMicrophone = true
        Task {
            microphoneStatus = await runtime.ensureMicrophoneAccess(defaults: defaults)
        }
    }

    public func resetMicrophoneAccess() {
        settings.enableMicrophone = true
        Task {
            microphoneStatus = await runtime.resetAndRequestMicrophoneAccess(defaults: defaults)
        }
    }

    /// Opens Steam so the user can sign in (also used by the "Open Steam" button).
    public func openSteam() {
        Task {
            guard !(await runtime.isClientRunning(inEngine: paths.wineBundle)) else { return }
            await prepareEngineAndMicrophoneForSteam()
            steamLaunchGraceUntil = Date().addingTimeInterval(25)
            try? runtime.launchSteamClient(paths: paths, manifest: manifest, arguments: [], environment: environment.setup(), logName: "steam-setup.log")
        }
    }

    private func ensureSignInAndGame() async throws {
        let kit = steam
        if kit.isGameInstalled {
            activePrompt = nil
            set(.signIn, .done)
            set(.game, .done)
            return
        }

        let env = environment.setup()
        if !(await runtime.isClientRunning(inEngine: paths.wineBundle)) {
            set(.signIn, .running(progress: nil, detail: L("Starting Steam")))
            await prepareEngineAndMicrophoneForSteam()
            steamLaunchGraceUntil = Date().addingTimeInterval(25)
            try runtime.launchSteamClient(paths: paths, manifest: manifest, arguments: [], environment: env, logName: "steam-setup.log")
        }

        var installRequestedAt: Date?
        var announcedSignIn = false
        while true {
            try Task.checkCancellation()
            if kit.isGameInstalled { break }

            let steamUp = await runtime.isClientRunning(inEngine: paths.wineBundle) || Date() < steamLaunchGraceUntil
            if kit.appManifest != nil, !steamUp {
                // Steam was closed in the middle of the download; ask the user to open it again.
                set(.signIn, .done)
                activePrompt = .steamClosedReopen
                set(.game, .waitingForUser(L("Steam is not running — open it to continue")))
            } else if let info = kit.appManifest {
                set(.signIn, .done)
                activePrompt = nil
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
                    try runtime.requestGameInstall(paths: paths, manifest: manifest, environment: env)
                    installRequestedAt = Date()
                }
                activePrompt = .installGame
                set(.game, .waitingForUser(L("Click Install in the Steam window")))
            } else {
                if !announcedSignIn {
                    announcedSignIn = true
                    Log.shared.info("Waiting for the user to sign in to Steam")
                }
                if steamUp {
                    activePrompt = .signInSteam
                    set(.signIn, .waitingForUser(L("Sign in to Steam in the window that opened")))
                } else {
                    activePrompt = .steamClosedReopen
                    set(.signIn, .waitingForUser(L("Steam is not running — open it to continue")))
                }
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        activePrompt = nil
        set(.signIn, .done)
        set(.game, .done)
    }

    // MARK: Download helper

    private func download(_ item: RuntimeManifest.Download, to destination: URL, stage: SetupStage, label: String, share: Double) async throws {
        speedSample = nil
        set(stage, .running(progress: 0, detail: label))
        try await runtime.download(item, to: destination) { [weak self] p in
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
        guard case .ready = phase, playTask == nil, setupTask == nil, !isMaintaining, acquireLock(forPlay: true) else { return }
        operationGeneration &+= 1
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
        let execName = paths.profile.executableName
        do {
            if await runtime.isAnyProcessRunning(inEngine: paths.wineBundle) {
                phase = .playing(L("Restarting Steam"))
                await runtime.shutdownSteam(paths: paths, manifest: manifest, environment: environment.setup())
            }
            try runtime.isolatePrefix(paths.prefixDir)

            display = runtime.primaryDisplay()
            phase = .playing(L("Preparing"))
            // Probe Windows monitor modes even when custom resolution is active so Settings and Diagnostics know supported modes.
            if displayModes == nil {
                displayModes = await probeDisplayModes()
            }
            let resolution = plannedResolution
            if settings.useCustomResolution {
                Log.shared.info("Using custom resolution \(resolution)")
            } else if let modes = displayModes {
                Log.shared.info("Windows monitor \(modes.current), \(modes.all.count) modes; planned \(settings.resolution(for: modes.current)), writing \(resolution)")
            }

            seedFirstRunFiles(resolution)
            applyTuning(resolution)
            if settings.enableSpeedPatches {
                let speedStatus = installSpeedLibraries()
                Log.shared.info("Speed libraries: \(speedStatus)")
            } else if let gameDir = steam.gameDirectory {
                let restored = GameFiles.restoreSpeedLibraries(in: gameDir)
                if restored > 0 { Log.shared.info("Speed patches disabled; restored \(restored) original libraries") }
            }
            if let gameDir = steam.gameDirectory {
                let applyNotch = settings.enableNotchHUD && (display?.hasNotch == true)
                let notchStatus = GameFiles.applyNotchHUD(in: gameDir, enabled: applyNotch)
                Log.shared.info("Notch HUD (\(applyNotch ? "enabled" : "disabled")): \(notchStatus)")
            }

            try? FileManager.default.createDirectory(at: paths.patchLogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: paths.patchLogFile)
            pruneFrameTimes()

            try Task.checkCancellation()
            phase = .playing(L("Starting Steam"))
            await prepareEngineAndMicrophoneForSteam()
            try Task.checkCancellation()
            try runtime.launchSteamClient(
                paths: paths,
                manifest: manifest,
                arguments: ["-applaunch", String(paths.profile.steamAppID)],
                environment: environment.game(settings: settings),
                logName: "game-session.log"
            )
            Log.shared.info("Launched at \(resolution) (speedPatches=\(settings.enableSpeedPatches), multithreaded=\(settings.multithreadedEngine))")

            var elapsedNanoseconds: UInt64 = 0
            var updateElapsedNanoseconds: UInt64 = 0
            var lastDownloadedBytes: Int64 = -1
            var updateStallNanoseconds: UInt64 = 0
            let stepNs = max(pollIntervalNanoseconds, 1)
            let timeoutNs: UInt64 = 600 * 1_000_000_000
            let updateTimeoutNs: UInt64 = 3600 * 1_000_000_000
            waitLaunch: while true {
                try Task.checkCancellation()
                switch await runtime.checkGameRunning(inEngine: paths.wineBundle, executableName: execName) {
                case .running:
                    startDialogHelper()
                    break waitLaunch
                case .unknown(let reason):
                    Log.shared.warn("Process scan uncertain while starting game: \(reason)")
                case .notRunning:
                    break
                }
                if let info = steam.appManifest, info.isUpdating {
                    updateElapsedNanoseconds &+= stepNs
                    if updateElapsedNanoseconds > updateTimeoutNs { throw SetupError.gameDidNotStart }
                    if info.bytesDownloaded != lastDownloadedBytes {
                        lastDownloadedBytes = info.bytesDownloaded
                        updateStallNanoseconds = 0
                    } else {
                        updateStallNanoseconds &+= stepNs
                    }
                    if updateStallNanoseconds > 45 * 1_000_000_000 {
                        phase = .playing(L("Waiting for Steam — sign in there if it asks"))
                    } else {
                        phase = .playing(L("Waiting for Steam update to finish"))
                    }
                } else {
                    elapsedNanoseconds &+= stepNs
                    if elapsedNanoseconds > timeoutNs { throw SetupError.gameDidNotStart }
                    if elapsedNanoseconds > 30 * 1_000_000_000 {
                        phase = .playing(L("Waiting for Steam — sign in there if it asks"))
                    } else if elapsedNanoseconds > 8 * 1_000_000_000 {
                        phase = .playing(L("Launching Cossacks 3"))
                    }
                }
                try await Task.sleep(nanoseconds: stepNs)
            }

            phase = .playing(L("Running"))
            let runStarted = Date()
            try await waitUntilGameExits(executableName: execName)
            let runDuration = Date().timeIntervalSince(runStarted)
            await finishSession(resolution: resolution, runDuration: runDuration)
        } catch is CancellationError {
            Log.shared.info("Play cancelled")
            await runtime.shutdownSteam(paths: paths, manifest: manifest, environment: environment.setup())
            lastSessionNote = nil
            await reloadPatchReport()
            phase = .ready
        } catch {
            Log.shared.error("Play failed: \(error.localizedDescription)")
            await runtime.shutdownSteam(paths: paths, manifest: manifest, environment: environment.setup())
            lastSessionNote = error.localizedDescription
            await reloadPatchReport()
            phase = .ready
        }
    }

    private func waitUntilGameExits(executableName: String) async throws {
        var notRunningStreak = 0
        while true {
            try Task.checkCancellation()
            switch await runtime.checkGameRunning(inEngine: paths.wineBundle, executableName: executableName) {
            case .running:
                notRunningStreak = 0
            case .unknown(let reason):
                Log.shared.warn("Process scan failed during session: \(reason)")
                notRunningStreak = 0
            case .notRunning:
                notRunningStreak += 1
                if notRunningStreak >= 2 { return }
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    private func attachToRunningGame() {
        guard playTask == nil, setupTask == nil, !isMaintaining else { return }
        guard acquireLock(forPlay: true) else {
            phase = .ready
            return
        }
        operationGeneration &+= 1
        let execName = paths.profile.executableName
        phase = .playing(L("Running"))
        playTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.playTask = nil
                self.releaseLockIfIdle()
            }
            try? await self.waitUntilGameExits(executableName: execName)
            guard !Task.isCancelled else { return }
            await self.finishSession(resolution: self.plannedResolution)
        }
    }

    private func finishSession(resolution: Resolution, runDuration: TimeInterval? = nil) async {
        // A profile created during this session only now has a profile.cfg.
        applyTuning(resolution)
        if settings.quitSteamAfterGame {
            phase = .playing(L("Saving to Steam Cloud"))
            await runtime.shutdownSteam(paths: paths, manifest: manifest, environment: environment.setup())
        }
        if let runDuration {
            let sessionLogURL = paths.logsDir.appendingPathComponent("game-session.log")
            let logText = (try? Data(contentsOf: sessionLogURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let outcome = LaunchOutcome.classify(
                duration: runDuration,
                logTail: String(logText.suffix(16_384)),
                resolution: resolution,
                profile: paths.profile
            )
            if let note = outcome.userNote(for: paths.profile) {
                Log.shared.warn("Early game exit (\(Int(runDuration))s): \(outcome)")
                lastSessionNote = note
            } else {
                lastSessionNote = nil
            }
        } else {
            lastSessionNote = nil
        }
        await reloadPatchReport()
        phase = .ready
    }

    private func pruneFrameTimes() {
        let fm = FileManager.default
        let current = paths.logsDir.appendingPathComponent("frames.ns")
        let previous = paths.logsDir.appendingPathComponent("frames.ns.1")
        if fm.fileExists(atPath: current.path) {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: current, to: previous)
        }
        if let size = (try? fm.attributesOfItem(atPath: previous.path)[.size] as? Int64),
           size > Self.maxFrameTimesArchiveBytes {
            try? fm.removeItem(at: previous)
        }
    }

    /// Writes the files the game needs on a fresh install (see `GameBootstrap`); existing files are left alone.
    private func seedFirstRunFiles(_ resolution: Resolution) {
        Log.shared.info("Selected Windows user folder: \(paths.windowsUserDir?.lastPathComponent ?? "none")")
        let usersDir = paths.driveC.appendingPathComponent("users", isDirectory: true)
        let userDirectories = (try? FileManager.default.contentsOfDirectory(at: usersDir, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
        Log.shared.info("Directories in drive_c/users: \(userDirectories?.joined(separator: ", ") ?? "unavailable")")
        if let gameDir = steam.gameDirectory {
            let iniURL = gameDir.appendingPathComponent("cossacks.ini")
            if let text = try? String(contentsOf: iniURL, encoding: .isoLatin1) {
                let value = text.components(separatedBy: .newlines).compactMap { line -> String? in
                    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2, parts[0] == "UseMultithreadedMode" else { return nil }
                    return parts[1]
                }.first
                Log.shared.info("cossacks.ini UseMultithreadedMode: \(value ?? "not found")")
            }
        }
        guard let docsDir = paths.gameDocumentsDir, let gameDir = steam.gameDirectory else { return }
        let locales = ((try? FileManager.default.contentsOfDirectory(atPath: gameDir.appendingPathComponent("data/locale").path)) ?? [])
        let language = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        let loginUsers = paths.steamDir.appendingPathComponent("config/loginusers.vdf")
        let persona = (try? String(contentsOf: loginUsers, encoding: .utf8)).flatMap(GameBootstrap.personaName(fromLoginUsers:))
        do {
            let created = try GameBootstrap.seed(
                documentsGameDir: docsDir,
                profileName: GameBootstrap.sanitizedProfileName(persona),
                locale: GameBootstrap.localeFolder(languageCode: language, available: locales),
                resolution: resolution,
                multithreaded: settings.multithreadedEngine
            )
            if !created.isEmpty { Log.shared.info("First-run files created: \(created.count)") }
        } catch {
            Log.shared.warn("Could not create first-run files: \(error.localizedDescription)")
        }
    }

    private func applyTuning(_ resolution: Resolution) {
        guard let dir = paths.gameProfilesDir else { return }
        do {
            let outcome = try ProfileTuner.apply(resolution: resolution, multithreaded: settings.multithreadedEngine, profilesDir: dir)
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
            try runtime.launchDialogHelper(
                paths: paths,
                arguments: [SteppePaths.dialogHelperWindowsPath, "600"],
                environment: environment.game(settings: settings),
                logName: "dialog-helper.log"
            )
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
        return await runtime.probeDisplayModes(paths: paths, environment: environment.game(settings: settings))
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

    private func installSpeedLibraries() -> [GameFiles.Status] {
        guard let nativeDir, let gameDir = steam.gameDirectory else { return [] }
        return GameFiles.installSpeedLibraries(from: nativeDir, into: gameDir, knownOriginals: manifest.originalGameDLLs)
    }

    /// Force-closes the game, Steam and every Wine process of the prefix.
    public func forceStop() {
        playTask?.cancel()
        Task {
            await runtime.killAllWine(paths: paths, environment: environment.setup())
            await refresh()
        }
    }

    // MARK: - Maintenance

    /// Restores the game's original DLLs and HUD files when idle.
    @discardableResult
    public func restoreOriginalGameFiles() -> Int {
        guard !isBusy, let gameDir = steam.gameDirectory else { return 0 }
        let hadLock = (installLock != nil)
        guard acquireLock(forPlay: true) else { return 0 }
        defer {
            if !hadLock { releaseLockIfIdle() }
        }
        let count = GameFiles.restoreOriginals(in: gameDir)
        cachedPatchReport = .empty
        Task { await reloadPatchReport() }
        return count
    }

    /// Re-checks engine, frameworks and Wine prefix settings (preserving user saves and microphone permission).
    public func repair() {
        guard !isBusy else { return }
        autoSetupSuppressed = false
        forcePrefixRepair = true
        cachedPatchReport = .empty
        for stage in SetupStage.allCases { stages[stage] = .pending }
        startSetup()
    }

    /// Deletes Steppe-owned files from the install folder cleanly without touching unrelated user files.
    public func uninstall() async {
        guard !isMaintaining else { return }
        isMaintaining = true
        operationGeneration &+= 1
        autoSetupSuppressed = false
        forcePrefixRepair = false
        let setup = setupTask, play = playTask
        setup?.cancel()
        play?.cancel()
        await setup?.value
        await play?.value
        guard acquireLock(forPlay: false) else {
            isMaintaining = false
            return
        }
        await runtime.killAllWine(paths: paths, environment: environment.setup())
        if configureGlobalLogger {
            Log.shared.configure(fileURL: nil)
        }

        let uninstallPaths = paths
        let ownedTargets: [URL] = [
            uninstallPaths.engineDir,
            uninstallPaths.frameworksDir,
            uninstallPaths.downloadsDir,
            uninstallPaths.logsDir,
            uninstallPaths.root.appendingPathComponent("prefixes", isDirectory: true),
            uninstallPaths.stateFile,
            uninstallPaths.settingsFile,
            uninstallPaths.rootMarker,
            uninstallPaths.root.appendingPathComponent("engine.tmp", isDirectory: true),
            uninstallPaths.root.appendingPathComponent("frameworks.tmp", isDirectory: true),
        ]
        // Keep installLock held while deleting Steppe-owned entries so another process cannot race into the partial directory.
        let rootDir = uninstallPaths.root
        let lockFile = rootDir.appendingPathComponent(".steppe.lock")
        await Task.detached {
            let fm = FileManager.default
            for item in ownedTargets {
                try? fm.removeItem(at: item)
            }
            try? fm.removeItem(at: lockFile)
        }.value
        installLock = nil
        if (try? FileManager.default.contentsOfDirectory(atPath: rootDir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: rootDir)
        }

        defaults.removeObject(forKey: Self.rootDefaultsKey)
        paths = SteppePaths(root: rootOverride ?? SteppePaths.defaultRoot(), profile: paths.profile)
        displayModes = nil
        cachedPatchReport = .empty
        lastSessionNote = nil
        activePrompt = nil
        rosettaMissing = false
        settingsLoaded = false
        settings = AppSettings()
        if configureGlobalLogger {
            Log.shared.configure(fileURL: paths.appLogFile)
        }
        for stage in SetupStage.allCases { stages[stage] = .pending }
        isMaintaining = false
        phase = .needsSetup
        await refresh(allowAutoSetup: false)
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
    case externalDriveNotConnected(String)
    case engineLayout
    case gameDidNotStart

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let a = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return L("Not enough free disk space: %@ needed, %@ available. Free up space or choose another disk.", n, a)
        case .externalDriveNotConnected(let volumeName):
            return L("The external drive \"%@\" is not connected. Reconnect it or choose another location.", volumeName)
        case .engineLayout: return L("The downloaded files were not laid out as expected. Try again.")
        case .gameDidNotStart: return L("Cossacks 3 did not start. Check the Steam window for a prompt and try again.")
        }
    }
}
