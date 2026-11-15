import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let widthRange = 640...7680
    public static let heightRange = 480...4320

    public var schemaVersion: Int = AppSettings.currentSchemaVersion
    public var preset: PerformancePreset = .balanced
    /// Used when `useCustomResolution` is on.
    public var customResolution: Resolution = Resolution(width: 1710, height: 1112)
    public var useCustomResolution = false
    /// Close Steam (and Wine) when the game exits so nothing keeps using the CPU.
    public var quitSteamAfterGame = true
    /// Opt-in: also patch the game's geometry math (not verified for multiplayer).
    public var experimentalMathPatches = false
    /// Writes per-frame timings to the log folder for benchmarking and bug reports.
    public var recordFrameTimes = false
    /// Requests macOS microphone permission for Steam Voice / overlays only when explicitly enabled.
    public var enableMicrophone = false
    /// Enables Steppe's performance libraries (`glfix`, `vorbis-fast`); turn off for safe-mode launch.
    public var enableSpeedPatches = true
    /// Automatically adjusts HUD spacing around MacBook camera notches.
    public var enableNotchHUD = true
    /// Enables Cossacks 3's multithreaded engine option in `profile.cfg`.
    public var multithreadedEngine = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One invalid value must not reset the others: each field falls back on its own.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let decodedVersion: Int = value(.schemaVersion, 1)
        preset = value(.preset, PerformancePreset.balanced)
        customResolution = Self.clampedResolution(value(.customResolution, Resolution(width: 1710, height: 1112)))
        useCustomResolution = value(.useCustomResolution, false)
        quitSteamAfterGame = value(.quitSteamAfterGame, true)
        experimentalMathPatches = value(.experimentalMathPatches, false)
        recordFrameTimes = value(.recordFrameTimes, false)
        enableMicrophone = value(.enableMicrophone, false)
        enableSpeedPatches = value(.enableSpeedPatches, true)
        enableNotchHUD = value(.enableNotchHUD, true)
        multithreadedEngine = value(.multithreadedEngine, true)
        schemaVersion = max(decodedVersion, Self.currentSchemaVersion)
    }

    public static func clampedResolution(_ resolution: Resolution) -> Resolution {
        Resolution(
            width: min(max(resolution.width, widthRange.lowerBound), widthRange.upperBound),
            height: min(max(resolution.height, heightRange.lowerBound), heightRange.upperBound)
        )
    }

    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return decoded
    }

    public func save(to url: URL) throws {
        var sanitized = self
        sanitized.schemaVersion = Self.currentSchemaVersion
        sanitized.customResolution = Self.clampedResolution(customResolution)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(sanitized).write(to: url, options: .atomic)
    }

    /// The resolution the game should render at on `display`.
    public func resolution(for display: Resolution) -> Resolution {
        useCustomResolution ? Self.clampedResolution(customResolution) : ResolutionPlanner.plan(display: display, preset: preset)
    }

    /// The resolution to write before a launch. Custom resolutions are returned unchanged.
    /// Otherwise, uses the monitor Windows reported and snaps the plan to an enumerable mode.
    public func resolution(for display: Resolution, modes: DisplayModes?) -> Resolution {
        if useCustomResolution { return Self.clampedResolution(customResolution) }
        guard let modes else { return resolution(for: display) }
        return modes.snap(resolution(for: modes.current))
    }
}
