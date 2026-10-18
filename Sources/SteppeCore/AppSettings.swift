import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
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

    public init() {}

    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return decoded
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The resolution the game should render at on `display`.
    public func resolution(for display: Resolution) -> Resolution {
        useCustomResolution ? customResolution : ResolutionPlanner.plan(display: display, preset: preset)
    }
}
