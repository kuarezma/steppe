import Foundation

/// Installs Steppe's replacement audio libraries into the game folder.
///
/// A file is only replaced while it is still the unmodified original shipped by the game; a backup
/// is kept as `<name>.steppe-orig`. If Steam updates or verifies the game the originals come back
/// and are replaced again on the next launch.
public enum GameFiles {
    public static let libraryNames = ["ogg.dll", "vorbis.dll", "vorbisfile.dll"]

    public enum Status: Equatable, Sendable {
        case installed(String)
        case alreadyCurrent(String)
        case skippedUnknownFile(String)
        case missing(String)
    }

    /// Sidecar file recording the SHA-256 of every library Steppe installed, so a newer Steppe can tell its own
    /// older files apart from a modified or updated game file.
    static let installedRecordName = ".steppe-audio-installed.json"

    private static func readInstalledRecord(in gameDir: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: gameDir.appendingPathComponent(installedRecordName)),
              let record = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return record
    }

    private static func writeInstalledRecord(_ record: [String: String], in gameDir: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: gameDir.appendingPathComponent(installedRecordName), options: .atomic)
    }

    public static func installSpeedLibraries(from sourceDir: URL, into gameDir: URL, knownOriginals: [String: String]) -> [Status] {
        let fm = FileManager.default
        var results: [Status] = []
        var record = readInstalledRecord(in: gameDir)
        for name in libraryNames {
            let source = sourceDir.appendingPathComponent(name)
            let target = gameDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path), let ours = try? Hashing.sha256(of: source) else {
                results.append(.missing(name))
                continue
            }
            guard fm.fileExists(atPath: target.path), let current = try? Hashing.sha256(of: target) else {
                results.append(.missing(name))
                continue
            }
            if current == ours {
                record[name] = ours
                results.append(.alreadyCurrent(name))
                continue
            }
            // Replace only the verified original, or a file we installed ourselves earlier (an older Steppe).
            let isOriginal = knownOriginals[name] == current
            let isOurOlderFile = record[name] == current
            guard isOriginal || isOurOlderFile else {
                results.append(.skippedUnknownFile(name))
                continue
            }
            let backup = target.appendingPathExtension("steppe-orig")
            do {
                if isOriginal, !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: target, to: backup) }
                let staged = target.appendingPathExtension("steppe-new")
                try? fm.removeItem(at: staged)
                try fm.copyItem(at: source, to: staged)
                try replaceFile(at: target, with: staged)
                record[name] = ours
                results.append(.installed(name))
            } catch {
                Log.shared.error("Could not install \(name): \(error.localizedDescription)")
                results.append(.skippedUnknownFile(name))
            }
        }
        writeInstalledRecord(record, in: gameDir)
        return results
    }

    /// Puts the original libraries back (used by "Restore original game files").
    @discardableResult
    public static func restoreOriginals(in gameDir: URL) -> Int {
        let fm = FileManager.default
        var restored = 0
        for name in libraryNames {
            let target = gameDir.appendingPathComponent(name)
            let backup = target.appendingPathExtension("steppe-orig")
            guard fm.fileExists(atPath: backup.path) else { continue }
            if (try? replaceFile(at: target, with: backup)) != nil { restored += 1 }
        }
        return restored
    }

    /// Atomic replace where the volume supports it; exFAT and similar volumes can reject it (ENOTSUP),
    /// so fall back to a rollback-safe move that preserves `target` if moving `source` fails.
    static func replaceFile(at target: URL, with source: URL) throws {
        let fm = FileManager.default
        do {
            _ = try fm.replaceItemAt(target, withItemAt: source)
        } catch {
            guard fm.fileExists(atPath: source.path) else { throw error }
            let rollback = target.appendingPathExtension("steppe-rollback-\(UUID().uuidString)")
            let hadTarget = fm.fileExists(atPath: target.path)
            if hadTarget { try fm.moveItem(at: target, to: rollback) }
            do {
                try fm.moveItem(at: source, to: target)
                if hadTarget { try? fm.removeItem(at: rollback) }
            } catch let moveError {
                if hadTarget, !fm.fileExists(atPath: target.path) {
                    try? fm.moveItem(at: rollback, to: target)
                }
                throw moveError
            }
        }
    }
}


/// Summary of the speed-patch log written by the replacement audio library.
public struct PatchReport: Equatable, Sendable {
    public var applied: Int
    /// Patches that could not be applied (for example because the game was updated).
    public var skipped: Int
    /// Optional patches that are off by default.
    public var disabled: Int

    public init(applied: Int, skipped: Int, disabled: Int = 0) {
        self.applied = applied
        self.skipped = skipped
        self.disabled = disabled
    }

    public var isEmpty: Bool { applied == 0 && skipped == 0 && disabled == 0 }

    /// Lines look like `0x004d1870 applied` or `0x004a825c skipped: math disabled`.
    public static func parse(_ text: String) -> PatchReport {
        var report = PatchReport(applied: 0, skipped: 0)
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].hasPrefix("0x") else { continue }
            if parts[1].hasPrefix("applied") { report.applied += 1 }
            else if parts[1].hasPrefix("skipped: math disabled") { report.disabled += 1 }
            else if parts[1].hasPrefix("skipped") { report.skipped += 1 }
        }
        return report
    }

    public var summary: String {
        if isEmpty { return L("Not available yet") }
        if skipped == 0 { return L("Active") }
        return L("%@ active, %@ skipped (game version differs)", String(applied), String(skipped))
    }
}
