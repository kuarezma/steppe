import Foundation

public struct ComponentMarker: Codable, Equatable {
    public var name: String
    public var checksum: String
    public var patchRevision: Int
    public var installedAt: Date

    public init(name: String, checksum: String, patchRevision: Int) {
        self.name = name
        self.checksum = checksum
        self.patchRevision = patchRevision
        self.installedAt = Date()
    }

    public static func read(_ url: URL) -> ComponentMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ComponentMarker.self, from: data)
    }

    public func write(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum PrefixError: Error, LocalizedError {
    case refusingToDeleteGameData
    case creationFailed

    public var errorDescription: String? {
        switch self {
        case .refusingToDeleteGameData:
            return L("The Windows environment is damaged but contains your game. Steppe will not delete it. Use Settings → Uninstall Everything to start over, or ask for help on the project page.")
        case .creationFailed:
            return L("The Windows environment could not be created. Please try again.")
        }
    }
}

public enum PrefixBuilder {
    /// Creates a fresh 64-bit Windows prefix and applies Steppe's isolation and stability tweaks.
    public static func create(runner: WineRunner, environment: [String: String]) async throws {
        let paths = runner.paths
        let fm = FileManager.default
        if hasUserData(paths: paths) { throw PrefixError.refusingToDeleteGameData }
        try? fm.removeItem(at: paths.prefixDir)
        try fm.createDirectory(at: paths.prefixDir, withIntermediateDirectories: true)

        var env = environment
        env["WINEARCH"] = "win64"
        try await runner.run(["wineboot", "--init"], environment: env, timeout: 600)
        await runner.waitForIdle(environment: env, timeout: 120)

        try isolate(prefix: paths.prefixDir)

        // Without a debugger entry Wine can hang in winedbg when a helper service crashes.
        for key in [
            #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug"#,
            #"HKLM\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug"#,
        ] {
            try await runner.runChecked(["reg", "add", key, "/v", "Auto", "/t", "REG_SZ", "/d", "0", "/f"], environment: env, timeout: 60)
            try await runner.runChecked(["reg", "add", key, "/v", "Debugger", "/t", "REG_SZ", "/d", "", "/f"], environment: env, timeout: 60)
        }

        // Ensure CoreAudio is explicitly active for both output and MacBook microphone input (mmdevapi / DirectSoundCapture).
        let drivers = #"HKCU\Software\Wine\Drivers"#
        try await runner.runChecked(["reg", "add", drivers, "/v", "Audio", "/t", "REG_SZ", "/d", "coreaudio", "/f"], environment: env, timeout: 60)

        // Audio buffering that keeps the game's sound free of crackle on macOS (values measured on Apple silicon).
        let directSound = #"HKCU\Software\Wine\DirectSound"#
        for (name, value) in [("HelMargin", "10"), ("MaxHardwareChannels", "16"), ("SndQueueMax", "20"),
                              ("DefaultBitsPerSample", "16"), ("DefaultSampleRate", "44100")] {
            try await runner.runChecked(["reg", "add", directSound, "/v", name, "/t", "REG_DWORD", "/d", value, "/f"], environment: env, timeout: 60)
        }
        await runner.waitForIdle(environment: env, timeout: 120)
        try isolate(prefix: paths.prefixDir)

        guard fm.fileExists(atPath: paths.prefixDir.appendingPathComponent("system.reg").path),
              fm.fileExists(atPath: paths.driveC.appendingPathComponent("windows").path) else {
            throw PrefixError.creationFailed
        }
        let marker = ComponentMarker(name: "prefix", checksum: RuntimeManifest.current.engine.sha256, patchRevision: RuntimeManifest.current.patchRevision)
        try marker.write(paths.prefixMarker)
    }

    /// The prefix exists and looks like a complete Wine prefix. (Whether it needs a Wine update is `needsUpdate`.)
    public static func isHealthy(paths: SteppePaths) -> Bool {
        let fm = FileManager.default
        guard ComponentMarker.read(paths.prefixMarker) != nil else { return false }
        return fm.fileExists(atPath: paths.prefixDir.appendingPathComponent("system.reg").path)
            && fm.fileExists(atPath: paths.driveC.appendingPathComponent("windows").path)
    }

    /// True when the prefix was created by a different engine than the installed one.
    public static func needsUpdate(paths: SteppePaths) -> Bool {
        guard let marker = ComponentMarker.read(paths.prefixMarker) else { return false }
        return marker.checksum != RuntimeManifest.current.engine.sha256 || marker.patchRevision != RuntimeManifest.current.patchRevision
    }

    /// Anything the user would lose by deleting the prefix: an installed Steam library or game.
    static func hasUserData(paths: SteppePaths) -> Bool {
        let apps = paths.steamApps
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: apps.appendingPathComponent("common").path)) ?? []
        return !entries.isEmpty || FileManager.default.fileExists(atPath: paths.appManifestURL(appID: RuntimeManifest.current.steam.appID).path)
    }

    /// Lets a newer engine adopt an existing prefix (`wineboot -u`) without touching Steam or the game.
    public static func update(runner: WineRunner, environment: [String: String]) async throws {
        try await runner.run(["wineboot", "-u"], environment: environment, timeout: 600)
        await runner.waitForIdle(environment: environment, timeout: 120)
        try isolate(prefix: runner.paths.prefixDir)
        let marker = ComponentMarker(name: "prefix", checksum: RuntimeManifest.current.engine.sha256, patchRevision: RuntimeManifest.current.patchRevision)
        try marker.write(runner.paths.prefixMarker)
    }

    /// Cuts the prefix off from the Mac's file system:
    /// removes drive mappings other than C: and replaces user-folder symlinks (Desktop, Documents, …) with real folders.
    public static func isolate(prefix: URL) throws {
        let fm = FileManager.default
        let dosdevices = prefix.appendingPathComponent("dosdevices")
        if let entries = try? fm.contentsOfDirectory(atPath: dosdevices.path) {
            for entry in entries where entry.lowercased() != "c:" {
                try fm.removeItem(at: dosdevices.appendingPathComponent(entry))
            }
        }
        // C: must point at the prefix's own drive_c, nowhere else.
        let cDrive = dosdevices.appendingPathComponent("c:")
        if fm.fileExists(atPath: dosdevices.path), (try? fm.destinationOfSymbolicLink(atPath: cDrive.path)) != "../drive_c" {
            try? fm.removeItem(at: cDrive)
            try fm.createSymbolicLink(atPath: cDrive.path, withDestinationPath: "../drive_c")
        }
        let driveC = prefix.appendingPathComponent("drive_c")
        if (try? driveC.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw PrefixError.creationFailed
        }
        let users = prefix.appendingPathComponent("drive_c/users")
        guard let userDirs = try? fm.contentsOfDirectory(atPath: users.path) else { return }
        for user in userDirs {
            let userDir = users.appendingPathComponent(user)
            guard let children = try? fm.contentsOfDirectory(atPath: userDir.path) else { continue }
            for child in children {
                let url = userDir.appendingPathComponent(child)
                let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                if isLink {
                    try fm.removeItem(at: url)
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                }
            }
        }
    }

    /// Same as `isolate`, but never throws; for use after steps where a failure should not abort the flow.
    public static func isolatePrefixQuietly(_ prefix: URL) {
        do { try isolate(prefix: prefix) } catch { Log.shared.warn("Prefix isolation failed: \(error.localizedDescription)") }
    }

    /// True if anything in the prefix still points outside of it.
    public static func escapesPrefix(prefix: URL) -> [String] {
        let fm = FileManager.default
        var leaks: [String] = []
        let dosdevices = prefix.appendingPathComponent("dosdevices")
        for entry in (try? fm.contentsOfDirectory(atPath: dosdevices.path)) ?? [] where entry.lowercased() != "c:" {
            leaks.append("dosdevices/\(entry)")
        }
        if let target = try? fm.destinationOfSymbolicLink(atPath: dosdevices.appendingPathComponent("c:").path), target != "../drive_c" {
            leaks.append("dosdevices/c: -> \(target)")
        }
        let users = prefix.appendingPathComponent("drive_c/users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            let userDir = users.appendingPathComponent(user)
            for child in (try? fm.contentsOfDirectory(atPath: userDir.path)) ?? [] {
                let url = userDir.appendingPathComponent(child)
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    leaks.append("users/\(user)/\(child)")
                }
            }
        }
        return leaks
    }
}
