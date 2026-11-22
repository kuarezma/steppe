import Foundation

/// The few fields of Steam's `appmanifest_<id>.acf` that Steppe reads.
/// Fields that identify the account (such as `LastOwner`) are deliberately never parsed.
public struct AppManifestInfo: Equatable, Sendable {
    public var stateFlags: Int
    public var installDir: String
    public var sizeOnDisk: Int64
    public var bytesToDownload: Int64
    public var bytesDownloaded: Int64

    /// Bit 4 = "fully installed".
    public var isFullyInstalled: Bool { stateFlags & 4 != 0 }

    /// Bit 2 (UpdateRequired) or bit 1024 (UpdateStarted).
    public var isUpdating: Bool { (stateFlags & (2 | 1024)) != 0 }

    public var downloadFraction: Double? {
        bytesToDownload > 0 ? min(1, Double(bytesDownloaded) / Double(bytesToDownload)) : nil
    }
}

public enum SteamACF {
    private static let allowedKeys: Set<String> = ["stateflags", "installdir", "sizeondisk", "bytestodownload", "bytesdownloaded"]

    public static func parse(_ text: String) -> AppManifestInfo? {
        var values: [String: String] = [:]
        let pattern = #"^\s*"([^"]+)"\s+"([^"]*)"\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            guard allowedKeys.contains(key), values[key] == nil else { continue }
            values[key] = ns.substring(with: match.range(at: 2))
        }
        guard let flags = values["stateflags"].flatMap({ Int($0) }) else { return nil }
        return AppManifestInfo(
            stateFlags: flags,
            installDir: values["installdir"] ?? "",
            sizeOnDisk: values["sizeondisk"].flatMap { Int64($0) } ?? 0,
            bytesToDownload: values["bytestodownload"].flatMap { Int64($0) } ?? 0,
            bytesDownloaded: values["bytesdownloaded"].flatMap { Int64($0) } ?? 0
        )
    }

    public static func read(at url: URL) -> AppManifestInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }
}

public struct SteamKit: Sendable {
    public let paths: SteppePaths
    public let runner: WineRunner
    public let manifest: RuntimeManifest

    public init(paths: SteppePaths, manifest: RuntimeManifest = .current) {
        self.paths = paths
        self.runner = WineRunner(paths: paths)
        self.manifest = manifest
    }

    public var isClientInstalled: Bool { FileManager.default.fileExists(atPath: paths.steamExe.path) }

    /// True once the user has signed in at least once (Steam writes this file after a successful login).
    public var hasSignedIn: Bool {
        let url = paths.steamDir.appendingPathComponent("config/loginusers.vdf")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 0
    }

    public var appManifest: AppManifestInfo? {
        SteamACF.read(at: paths.appManifestURL(appID: paths.profile.steamAppID))
    }

    public var gameDirectory: URL? {
        guard let info = appManifest, !info.installDir.isEmpty else { return nil }
        let common = paths.steamApps.appendingPathComponent("common", isDirectory: true).standardizedFileURL
        let candidate = common.appendingPathComponent(info.installDir, isDirectory: true).standardizedFileURL
        let prefix = common.path.hasSuffix("/") ? common.path : common.path + "/"
        guard candidate.path.hasPrefix(prefix), candidate.path != common.path else { return nil }
        return candidate
    }

    public var isGameInstalled: Bool {
        guard let info = appManifest, info.isFullyInstalled, let dir = gameDirectory else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(paths.profile.executableName).path)
    }

    /// Verifies DOS "MZ" header, PE offset at 0x3C, "PE\0\0" signature, and minimum size before running downloaded setup EXEs.
    public static func verifyPEExecutable(at url: URL, minimumBytes: Int64 = 512_000) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64, fileSize >= minimumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else {
            throw SteamError.invalidInstaller
        }
        defer { try? handle.close() }
        guard let dosHeader = try? handle.read(upToCount: 64), dosHeader.count == 64,
              dosHeader[0] == 0x4D, dosHeader[1] == 0x5A else {
            throw SteamError.invalidInstaller
        }
        let peOffset = UInt32(dosHeader[60])
            | (UInt32(dosHeader[61]) << 8)
            | (UInt32(dosHeader[62]) << 16)
            | (UInt32(dosHeader[63]) << 24)
        guard peOffset >= 64, Int64(peOffset) + 4 <= fileSize else {
            throw SteamError.invalidInstaller
        }
        try? handle.seek(toOffset: UInt64(peOffset))
        guard let peSig = try? handle.read(upToCount: 4), peSig.count == 4,
              peSig[0] == 0x50, peSig[1] == 0x45, peSig[2] == 0x00, peSig[3] == 0x00 else {
            throw SteamError.invalidInstaller
        }
    }

    /// Downloads Valve's official installer and runs it silently inside the prefix.
    public func installClient(environment: [String: String], progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        try await Downloader.download(
            url: manifest.steam.setupURL,
            to: paths.steamSetupDownload,
            expectedSHA256: nil,
            expectedSize: nil,
            progress: progress
        )
        try Self.verifyPEExecutable(at: paths.steamSetupDownload)
        // The prefix has no drive mapped to the Mac's file system, so the installer must live inside it.
        let fm = FileManager.default
        let staging = paths.driveC.appendingPathComponent("steppe-tmp", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("SteamSetup.exe")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: paths.steamSetupDownload, to: staged)
        try await runner.run(["C:\\steppe-tmp\\SteamSetup.exe", "/S", "/D=C:\\Steam"], environment: environment, timeout: 600)
        await runner.waitForIdle(environment: environment, timeout: 120)
        guard isClientInstalled else { throw SteamError.installerDidNotInstall }
        try? FileManager.default.removeItem(at: paths.steamSetupDownload)
    }

    /// Starts the Steam client (it keeps running in the background).
    @discardableResult
    public func launchClient(arguments: [String] = [], environment: [String: String], logName: String) throws -> Process {
        try runner.spawn(["C:\\Steam\\steam.exe"] + arguments, environment: environment, logName: logName)
    }

    /// Asks the running (or starting) client to install the game; Steam shows its own confirmation dialog.
    public func requestGameInstall(environment: [String: String]) throws {
        try runner.spawn(["C:\\Steam\\steam.exe", "steam://install/\(paths.profile.steamAppID)"], environment: environment, logName: "steam-install-request.log")
    }

    public func isClientRunning() async -> Bool {
        await ProcessScanner.processes(inEngine: paths.wineBundle).contains { $0.imageName == "steam.exe" }
    }

    /// Closes Steam gracefully (so Cloud saves sync), then makes sure nothing of the prefix is left.
    /// Detached so cancellation of the outer workflow never skips graceful shutdown.
    public func shutdown(environment: [String: String]) async {
        let kit = self
        await Task.detached(priority: .userInitiated) {
            if await kit.isClientRunning() {
                _ = try? await kit.runner.run(["C:\\Steam\\steam.exe", "-shutdown"], environment: environment, timeout: 45)
                for _ in 0..<20 {
                    if !(await kit.isClientRunning()) { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            await kit.runner.killAll(environment: environment)
        }.value
    }
}

public enum SteamError: Error, LocalizedError {
    case installerDidNotInstall
    case invalidInstaller

    public var errorDescription: String? {
        switch self {
        case .installerDidNotInstall: return L("The Steam installer finished but Steam was not installed.")
        case .invalidInstaller: return L("The downloaded Steam installer was not a valid Windows executable.")
        }
    }
}
