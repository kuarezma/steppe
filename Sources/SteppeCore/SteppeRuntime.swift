import Foundation

/// Abstracts OS/network/process side effects for `SteppeController` so lifecycle logic is unit-testable.
public protocol SteppeRuntime: Sendable {
    @MainActor func primaryDisplay() -> DisplayInfo
    func diskStatus(at root: URL) async -> SystemInfo.DiskStatus
    func acquireLock(root: URL) -> Result<InstallLock, LockFailure>
    func isRosettaInstalled() async -> Bool
    func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult?
    func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck
    func isClientRunning(inEngine bundle: URL) async -> Bool
    func isAnyProcessRunning(inEngine bundle: URL) async -> Bool
    func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async
    func killAllWine(paths: SteppePaths, environment: [String: String]) async
    func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws
    func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws
    func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws
    func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes?
    func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws
    func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws
    func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws
    func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool
    func createPrefix(paths: SteppePaths, environment: [String: String]) async throws
    func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws
    func isolatePrefix(_ prefix: URL) throws
    func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws
    func ensureAudioEntitlements(engineRoot: URL) async
    func microphoneStatus() -> MicrophoneStatus
    @MainActor func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus
    @MainActor func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus
}

public struct LiveSteppeRuntime: SteppeRuntime {
    public init() {}

    @MainActor
    public func primaryDisplay() -> DisplayInfo {
        DisplayInfo.primary()
    }

    public func diskStatus(at root: URL) async -> SystemInfo.DiskStatus {
        await Task.detached { SystemInfo.diskStatus(at: root) }.value
    }

    public func acquireLock(root: URL) -> Result<InstallLock, LockFailure> {
        InstallLock.acquire(root: root)
    }

    public func isRosettaInstalled() async -> Bool {
        await SystemInfo.rosettaInstalled()
    }

    public func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval?) async -> CommandResult? {
        try? await ProcessRunner.run(executable, arguments: arguments, timeout: timeout)
    }

    public func checkGameRunning(inEngine bundle: URL, executableName: String) async -> GameRunningCheck {
        await ProcessScanner.checkGameRunning(inEngine: bundle, executableName: executableName)
    }

    public func isClientRunning(inEngine bundle: URL) async -> Bool {
        await ProcessScanner.processes(inEngine: bundle).contains { $0.imageName == "steam.exe" }
    }

    public func isAnyProcessRunning(inEngine bundle: URL) async -> Bool {
        await !(ProcessScanner.processes(inEngine: bundle).isEmpty)
    }

    public func shutdownSteam(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) async {
        await SteamKit(paths: paths, manifest: manifest).shutdown(environment: environment)
    }

    public func killAllWine(paths: SteppePaths, environment: [String: String]) async {
        await WineRunner(paths: paths).killAll(environment: environment)
    }

    public func launchSteamClient(paths: SteppePaths, manifest: RuntimeManifest, arguments: [String], environment: [String: String], logName: String) throws {
        try SteamKit(paths: paths, manifest: manifest).launchClient(arguments: arguments, environment: environment, logName: logName)
    }

    public func requestGameInstall(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String]) throws {
        try SteamKit(paths: paths, manifest: manifest).requestGameInstall(environment: environment)
    }

    public func launchDialogHelper(paths: SteppePaths, arguments: [String], environment: [String: String], logName: String) throws {
        try WineRunner(paths: paths).spawn(arguments, environment: environment, logName: logName)
    }

    public func probeDisplayModes(paths: SteppePaths, environment: [String: String]) async -> DisplayModes? {
        do {
            let result = try await WineRunner(paths: paths).run([SteppePaths.listModesWindowsPath], environment: environment, timeout: 60)
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

    public func download(_ item: RuntimeManifest.Download, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        try await Downloader.download(url: item.url, to: destination, expectedSHA256: item.sha256, expectedSize: item.sizeBytes, progress: progress)
    }

    public func extractArchive(_ archive: URL, to destination: URL, members: [String]?) async throws {
        try await Archive.extract(archive, to: destination, members: members ?? [])
    }

    public func patchEngine(bundle: URL, patch: RuntimeManifest.WinemacPatch) async throws {
        try await WinePatcher.apply(engineRoot: bundle, patch: patch)
    }

    public func isEnginePatched(bundle: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool {
        await WinePatcher.isPatched(engineRoot: bundle, patch: patch)
    }

    public func createPrefix(paths: SteppePaths, environment: [String: String]) async throws {
        try await PrefixBuilder.create(runner: WineRunner(paths: paths), environment: environment)
    }

    public func updatePrefix(paths: SteppePaths, environment: [String: String]) async throws {
        try await PrefixBuilder.update(runner: WineRunner(paths: paths), environment: environment)
    }

    public func isolatePrefix(_ prefix: URL) throws {
        try PrefixBuilder.isolate(prefix: prefix)
    }

    public func installSteamClient(paths: SteppePaths, manifest: RuntimeManifest, environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        try await SteamKit(paths: paths, manifest: manifest).installClient(environment: environment, progress: progress)
    }

    public func ensureAudioEntitlements(engineRoot: URL) async {
        await WinePatcher.ensureAudioEntitlements(engineRoot: engineRoot)
    }

    public func microphoneStatus() -> MicrophoneStatus {
        MicrophonePermission.status()
    }

    @MainActor
    public func ensureMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus {
        await MicrophonePermission.ensureAccessForSteam(defaults: defaults)
    }

    @MainActor
    public func resetAndRequestMicrophoneAccess(defaults: UserDefaults) async -> MicrophoneStatus {
        await MicrophonePermission.resetAndRequestAccess(defaults: defaults)
    }
}
