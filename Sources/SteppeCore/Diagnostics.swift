import Foundation

struct DiagnosticsSnapshot: Sendable {
    let system: SystemInfo
    let display: DisplayInfo?
    let displayModes: DisplayModes?
    let resolution: Resolution
    let settings: AppSettings
    let microphoneStatus: MicrophoneStatus
    let stageSummary: [String]
    let phase: String
    let freeBytes: Int64
    let gameManifest: AppManifestInfo?
    let paths: SteppePaths
    let manifest: RuntimeManifest
    let leaks: [String]

    init(
        system: SystemInfo,
        display: DisplayInfo?,
        displayModes: DisplayModes?,
        resolution: Resolution,
        settings: AppSettings,
        microphoneStatus: MicrophoneStatus,
        stageSummary: [String],
        phase: String,
        freeBytes: Int64,
        gameManifest: AppManifestInfo?,
        paths: SteppePaths,
        manifest: RuntimeManifest = .current,
        leaks: [String]
    ) {
        self.system = system
        self.display = display
        self.displayModes = displayModes
        self.resolution = resolution
        self.settings = settings
        self.microphoneStatus = microphoneStatus
        self.stageSummary = stageSummary
        self.phase = phase
        self.freeBytes = freeBytes
        self.gameManifest = gameManifest
        self.paths = paths
        self.manifest = manifest
        self.leaks = leaks
    }
}

/// Builds a plain-text report users can attach to bug reports. Personal data is redacted.
enum Diagnostics {
    @MainActor
    static func export(controller: SteppeController) async throws -> URL {
        let snapshot = controller.diagnosticsSnapshot
        return try await Task.detached(priority: .userInitiated) {
            let text = sanitizedReport(for: snapshot)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = snapshot.paths.logsDir.appendingPathComponent("diagnostics-\(stamp).txt")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        }.value
    }

    static func sanitizedReport(for snapshot: DiagnosticsSnapshot) -> String {
        var raw = report(for: snapshot)
        let comps = snapshot.paths.root.standardizedFileURL.pathComponents
        if comps.count > 2, comps[1] == "Volumes", !comps[2].isEmpty {
            let vol = comps[2]
            raw = raw.replacingOccurrences(of: "/Volumes/\(vol)", with: "/Volumes/<volume>")
            raw = raw.replacingOccurrences(of: "\"\(vol)\"", with: "\"<volume>\"")
            raw = raw.replacingOccurrences(of: "\\\"\(vol)\\\"", with: "\\\"<volume>\\\"")
        }
        return Redaction.redact(raw)
    }

    static func report(for s: DiagnosticsSnapshot) -> String {
        var lines: [String] = []
        let app = Bundle.main.infoDictionary
        lines.append("Steppe diagnostics")
        lines.append("App version: \(app?["CFBundleShortVersionString"] as? String ?? "dev") (\(app?["CFBundleVersion"] as? String ?? "-"))")
        lines.append("Mac: \(s.system.chipName), \(s.system.memoryGB) GB, macOS \(s.system.macOSVersion)")
        if let d = s.display {
            lines.append("Display: \(d.size) @\(d.scale)x, up to \(d.maxRefreshRate) Hz")
        }
        if let m = s.displayModes {
            lines.append("Windows monitor: \(m.current), modes: \(m.all.map(\.description).joined(separator: " "))")
        } else {
            lines.append("Windows monitor: not probed yet")
        }
        lines.append("Render resolution: \(s.resolution) (preset: \(s.settings.preset.rawValue), custom: \(s.settings.useCustomResolution))")
        lines.append("Settings: quitSteamAfterGame=\(s.settings.quitSteamAfterGame) speedPatches=\(s.settings.enableSpeedPatches) notchHUD=\(s.settings.enableNotchHUD) multithreaded=\(s.settings.multithreadedEngine) mic=\(s.settings.enableMicrophone) mathPatches=\(s.settings.experimentalMathPatches) frameTimes=\(s.settings.recordFrameTimes)")
        lines.append("Microphone permission: \(s.microphoneStatus.rawValue)")
        lines.append("Free disk: \(ByteCountFormatter.string(fromByteCount: s.freeBytes, countStyle: .file))")
        lines.append("Engine: \(s.manifest.engine.name), frameworks: \(s.manifest.template.name)")
        lines.append("Phase: \(s.phase)")
        lines.append("Stages:")
        lines.append(contentsOf: s.stageSummary.map { "  \($0)" })
        if let g = s.gameManifest {
            lines.append("Game: stateFlags=\(g.stateFlags) sizeOnDisk=\(g.sizeOnDisk)")
        } else {
            lines.append("Game: not installed")
        }
        lines.append("Prefix isolation leaks: \(s.leaks.isEmpty ? "none" : s.leaks.joined(separator: ", "))")
        if let patchLog = logTail(at: s.paths.patchLogFile), !patchLog.isEmpty {
            lines.append("Speed patches:")
            lines.append(patchLog)
        }
        for name in ["steam-setup.log", "game-session.log", "dialog-helper.log"] {
            let url = s.paths.logsDir.appendingPathComponent(name)
            if let text = logTail(at: url) {
                let tail = text.split(separator: "\n", omittingEmptySubsequences: true)
                    .filter { !$0.contains("hid:") && !$0.contains("[mvk-info]") }
                    .suffix(40).joined(separator: "\n")
                if !tail.isEmpty {
                    lines.append("")
                    lines.append("\(name) (last lines):")
                    lines.append(tail)
                }
            }
        }
        if let gameDocs = s.paths.gameDocumentsDir,
           let gameLog = logTail(at: gameDocs.appendingPathComponent("log.txt")) {
            let tail = gameLog.split(separator: "\n", omittingEmptySubsequences: true).suffix(40).joined(separator: "\n")
            if !tail.isEmpty {
                lines.append("")
                lines.append("game log.txt (last lines):")
                lines.append(tail)
            }
        }
        let crashes = recentCrashReports()
        if !crashes.isEmpty {
            lines.append("")
            lines.append("Recent crash reports (last 7 days):")
            lines.append(contentsOf: crashes)
        }
        lines.append("")
        lines.append("Recent log:")
        lines.append(Log.shared.tail(lines: 200))
        return lines.joined(separator: "\n")
    }

    static func lossyText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func logTail(at url: URL, maxBytes: Int = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
            let data = try handle.read(upToCount: maxBytes) ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    static func recentCrashReports(now: Date = Date(), directory: URL? = nil) -> [String] {
        let fm = FileManager.default
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        return urls.compactMap { url -> (Date, String)? in
            let name = url.lastPathComponent
            let lower = name.lowercased()
            guard lower.hasSuffix(".ips") || lower.hasSuffix(".crash"),
                  lower.contains("wine") || lower.contains("steppe") || lower.contains("cossacks") else {
                return nil
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard modified >= cutoff else { return nil }
            let preview = (lossyText(at: url) ?? "").split(separator: "\n", omittingEmptySubsequences: true).prefix(12).joined(separator: " | ")
            return (modified, preview.isEmpty ? name : "\(name): \(preview)")
        }
        .sorted { $0.0 > $1.0 }
        .prefix(3)
        .map(\.1)
    }
}
