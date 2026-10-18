import Foundation

/// Builds the environment for every Wine process Steppe starts.
public struct WineEnvironment: Sendable {
    public let paths: SteppePaths
    /// Directory of the bundled native helpers (`libglfix.dylib`, speed-patch DLLs).
    public let nativeDir: URL?

    /// Windows user name given to new prefixes, so nothing about the Mac account leaks into game or Steam files.
    public static let defaultWindowsUserName = "steppe"

    /// The user an existing prefix was created with (new prefixes use `defaultWindowsUserName`).
    public var windowsUserName: String {
        paths.windowsUserDir?.lastPathComponent ?? Self.defaultWindowsUserName
    }

    public init(paths: SteppePaths, nativeDir: URL?) {
        self.paths = paths
        self.nativeDir = nativeDir
    }

    public var glfixLibrary: URL? { nativeDir?.appendingPathComponent("libglfix.dylib") }

    /// Environment for installation steps (wineboot, Steam setup, Steam sign-in). No GL shim, verbose errors.
    public func setup() -> [String: String] {
        var env = common()
        env["WINEDEBUG"] = "err+all,fixme-all"
        return env
    }

    /// Environment for playing: GL shim injected, logging off.
    public func game(settings: AppSettings) -> [String: String] {
        var env = common()
        env["WINEDEBUG"] = "-all"
        if let glfix = glfixLibrary, FileManager.default.fileExists(atPath: glfix.path) {
            env["DYLD_INSERT_LIBRARIES"] = glfix.path
            env["GLFIX_REMAP"] = "2"
        }
        env["STEPPE_PATCH_LOG"] = SteppePaths.patchLogWindowsPath
        if settings.experimentalMathPatches { env["STEPPE_MATH_PATCHES"] = "1" }
        if settings.recordFrameTimes {
            env["GLFIX_FRAMETIMES"] = paths.logsDir.appendingPathComponent("frames.ns").path
        }
        return env
    }

    func common() -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in ProcessInfo.processInfo.environment {
            if key.hasPrefix("WINE") || key.hasPrefix("DYLD_") || key.hasPrefix("GLFIX_") || key.hasPrefix("STEPPE_") { continue }
            env[key] = value
        }
        let bin = paths.wineBundle.appendingPathComponent("bin").path
        env["PATH"] = bin + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["WINEPREFIX"] = paths.prefixDir.path
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml=;mountmgr.sys=d"
        // ESYNC makes Wine's helper services spin at 100% CPU on this engine; keep it off.
        env["WINEESYNC"] = "0"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["USER"] = windowsUserName
        env["LOGNAME"] = windowsUserName
        env["DYLD_FALLBACK_LIBRARY_PATH"] = paths.frameworksDir.path + ":/usr/lib"
        return env
    }
}
