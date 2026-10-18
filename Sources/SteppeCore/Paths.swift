import Foundation

/// All on-disk locations Steppe uses, derived from a single root directory.
public struct SteppePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Steppe`
    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Steppe", isDirectory: true)
    }

    public var engineDir: URL { root.appendingPathComponent("engine", isDirectory: true) }
    public var wineBundle: URL { engineDir.appendingPathComponent(RuntimeManifest.current.engineArchiveRoot, isDirectory: true) }
    public var wineBinary: URL { wineBundle.appendingPathComponent("bin/wine") }
    public var wineserverBinary: URL { wineBundle.appendingPathComponent("bin/wineserver") }
    public var frameworksDir: URL { root.appendingPathComponent("frameworks", isDirectory: true) }
    public var downloadsDir: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    public var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var prefixDir: URL { root.appendingPathComponent("prefixes/cossacks3", isDirectory: true) }
    public var stateFile: URL { root.appendingPathComponent("state.json") }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var engineMarker: URL { engineDir.appendingPathComponent(".steppe-engine.json") }
    public var frameworksMarker: URL { frameworksDir.appendingPathComponent(".steppe-frameworks.json") }
    public var prefixMarker: URL { prefixDir.appendingPathComponent(".steppe-prefix.json") }
    /// The speed-patch DLLs are Windows code and cannot open macOS paths, so their log lives inside the prefix.
    public var patchLogFile: URL { driveC.appendingPathComponent("steppe-logs/speed-patches.log") }
    public static let patchLogWindowsPath = #"C:\steppe-logs\speed-patches.log"#
    public var appLogFile: URL { logsDir.appendingPathComponent("steppe.log") }

    /// Helper programs that run inside the prefix (copied from the app bundle when needed).
    public var toolsDir: URL { driveC.appendingPathComponent("steppe-tools", isDirectory: true) }
    public static let dialogHelperWindowsPath = #"C:\steppe-tools\dismiss-dialog.exe"#

    public var driveC: URL { prefixDir.appendingPathComponent("drive_c", isDirectory: true) }
    public var steamDir: URL { driveC.appendingPathComponent("Steam", isDirectory: true) }
    public var steamExe: URL { steamDir.appendingPathComponent("Steam.exe") }
    public var steamApps: URL { steamDir.appendingPathComponent("steamapps", isDirectory: true) }
    public var steamSetupDownload: URL { downloadsDir.appendingPathComponent("SteamSetup.exe") }

    /// Windows-side user directory (the single non-Public user in the prefix).
    public var windowsUserDir: URL? {
        let users = driveC.appendingPathComponent("users", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: users.path) else { return nil }
        let candidates = entries.filter { $0 != "Public" && !$0.hasPrefix(".") }.sorted()
        return candidates.first.map { users.appendingPathComponent($0, isDirectory: true) }
    }

    /// Where the game stores profiles (`profile.cfg` lives inside each profile).
    public var gameProfilesDir: URL? {
        windowsUserDir?.appendingPathComponent("Documents/cossacks/profiles", isDirectory: true)
    }

    public func appManifestURL(appID: Int) -> URL {
        steamApps.appendingPathComponent("appmanifest_\(appID).acf")
    }

    public func ensureDirectories() throws {
        for dir in [root, downloadsDir, logsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
