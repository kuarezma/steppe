import Foundation

struct DiagnosticsSnapshot {
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
    let leaks: [String]
}

/// Builds a plain-text report users can attach to bug reports. Personal data is redacted.
enum Diagnostics {
    @MainActor
    static func export(controller: SteppeController) throws -> URL {
        let snapshot = controller.diagnosticsSnapshot
        let text = Redaction.redact(report(for: snapshot))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = snapshot.paths.logsDir.appendingPathComponent("diagnostics-\(stamp).txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
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
        lines.append("Settings: quitSteamAfterGame=\(s.settings.quitSteamAfterGame) mathPatches=\(s.settings.experimentalMathPatches) frameTimes=\(s.settings.recordFrameTimes)")
        lines.append("Microphone permission: \(s.microphoneStatus.rawValue)")
        lines.append("Free disk: \(ByteCountFormatter.string(fromByteCount: s.freeBytes, countStyle: .file))")
        lines.append("Engine: \(RuntimeManifest.current.engine.name), frameworks: \(RuntimeManifest.current.template.name)")
        lines.append("Phase: \(s.phase)")
        lines.append("Stages:")
        lines.append(contentsOf: s.stageSummary.map { "  \($0)" })
        if let g = s.gameManifest {
            lines.append("Game: stateFlags=\(g.stateFlags) sizeOnDisk=\(g.sizeOnDisk)")
        } else {
            lines.append("Game: not installed")
        }
        lines.append("Prefix isolation leaks: \(s.leaks.isEmpty ? "none" : s.leaks.joined(separator: ", "))")
        if let patchLog = try? String(contentsOf: s.paths.patchLogFile, encoding: .utf8), !patchLog.isEmpty {
            lines.append("Speed patches:")
            lines.append(patchLog)
        }
        for name in ["steam-setup.log", "game-session.log", "dialog-helper.log"] {
            let url = s.paths.logsDir.appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
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
        lines.append("")
        lines.append("Recent log:")
        lines.append(Log.shared.tail(lines: 200))
        return lines.joined(separator: "\n")
    }
}
