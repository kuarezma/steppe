import Foundation
#if canImport(AppKit)
import AppKit
#endif

public struct SystemInfo: Sendable {
    public let chipName: String
    public let memoryGB: Int
    public let macOSVersion: String
    public let isAppleSilicon: Bool
    public let performanceCores: Int

    public static func detect() -> SystemInfo {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        let mem = ProcessInfo.processInfo.physicalMemory
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var isARM: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &isARM, &size, nil, 0)
        var perf: Int32 = 0
        var psize = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &perf, &psize, nil, 0)
        return SystemInfo(
            chipName: chip,
            memoryGB: Int((Double(mem) / 1_073_741_824).rounded()),
            macOSVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            isAppleSilicon: isARM == 1,
            performanceCores: Int(perf)
        )
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Free space usable for new files at `url` (nearest existing ancestor).
    /// `statfs` is used because the "important usage" resource value is 0 for volumes other than the startup disk.
    public static func freeBytes(at url: URL) -> Int64 {
        let components = url.standardizedFileURL.pathComponents
        if components.count > 2, components[1] == "Volumes" {
            // An unmounted external drive (or a leftover stub directory under /Volumes) must not fall back to the startup disk.
            let mountPoint = "/Volumes/" + components[2]
            var mountStats = statfs(), volumesStats = statfs()
            guard statfs(mountPoint, &mountStats) == 0, statfs("/Volumes", &volumesStats) == 0 else { return 0 }
            let isRootSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: mountPoint)) == "/"
            if !isRootSymlink && mountStats.f_fsid.val == volumesStats.f_fsid.val { return 0 }
        }
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        var stats = statfs()
        guard statfs(probe.path, &stats) == 0 else { return 0 }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }

    /// Whether x86_64 code can run (Rosetta 2 installed).
    public static func rosettaInstalled() async -> Bool {
        let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/arch"), arguments: ["-x86_64", "/usr/bin/true"], timeout: 20)
        return result?.exitCode == 0
    }
}

public struct DisplayInfo: Equatable, Sendable {
    /// Logical size in points, as the game sees it.
    public let size: Resolution
    public let scale: Double
    public let maxRefreshRate: Int
    public let name: String
    public let hasNotch: Bool

    public init(size: Resolution, scale: Double, maxRefreshRate: Int, name: String, hasNotch: Bool = false) {
        self.size = size
        self.scale = scale
        self.maxRefreshRate = maxRefreshRate
        self.name = name
        self.hasNotch = hasNotch
    }

    #if canImport(AppKit)
    /// The menu-bar display, which Wine's Mac driver makes the primary Windows monitor. `NSScreen.main`
    /// is the screen with the key window and can be a different display (issue 1).
    @MainActor
    public static func primary() -> DisplayInfo {
        let screen = NSScreen.screens.first ?? NSScreen.main
        guard let screen else {
            return DisplayInfo(size: Resolution(width: 1440, height: 900), scale: 2, maxRefreshRate: 60, name: "Unknown", hasNotch: false)
        }
        let f = screen.frame
        return DisplayInfo(
            size: Resolution(width: Int(f.width), height: Int(f.height)),
            scale: Double(screen.backingScaleFactor),
            maxRefreshRate: screen.maximumFramesPerSecond,
            name: screen.localizedName,
            hasNotch: screen.safeAreaInsets.top > 0
        )
    }
    #endif
}
