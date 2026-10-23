import Foundation

/// Edits the game's `profile.cfg` (a nested `struct.begin` / `struct.end` text format).
///
/// Only the `ScreenResolution` block is touched; every other byte is preserved.
public enum ProfileConfig {
    public static func screenResolution(in text: String) -> Resolution? {
        guard let span = resolutionSpan(in: text) else { return nil }
        return span.current
    }

    /// Returns the updated text, or `nil` if the file has no `ScreenResolution` block.
    public static func settingScreenResolution(_ resolution: Resolution, in text: String) -> String? {
        guard let span = resolutionSpan(in: text) else { return nil }
        var result = text
        // Replace the later value first, regardless of the field order.
        let replacements = [(span.widthValueRange, String(resolution.width)),
                            (span.heightValueRange, String(resolution.height))]
        for (range, value) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: value)
        }
        return result
    }

    private struct Span {
        let widthValueRange: Range<String.Index>
        let heightValueRange: Range<String.Index>
        let current: Resolution
    }

    private static func resolutionSpan(in text: String) -> Span? {
        guard let blockStart = text.range(of: #"ScreenResolution\s*:\s*struct\.begin"#, options: .regularExpression) else { return nil }
        guard let blockEnd = text.range(of: "struct.end", range: blockStart.upperBound..<text.endIndex) else { return nil }
        let body = blockStart.upperBound..<blockEnd.lowerBound
        func valueRange(_ key: String) -> (Range<String.Index>, Int)? {
            guard let match = text.range(of: "\\b\(key)\\s*=\\s*[0-9]+", options: .regularExpression, range: body) else { return nil }
            let line = text[match]
            guard let digits = line.range(of: #"[0-9]+$"#, options: .regularExpression),
                  let value = Int(line[digits]) else { return nil }
            return (digits, value)
        }
        guard let (wRange, w) = valueRange("Width"), let (hRange, h) = valueRange("Height") else { return nil }
        return Span(widthValueRange: wRange, heightValueRange: hRange, current: Resolution(width: w, height: h))
    }
}

public enum ProfileTuner {
    public struct Outcome: Equatable, Sendable {
        public var updated: [String] = []
        public var unchanged: [String] = []
        public var skipped: [String] = []
    }

    /// Writes `resolution` into every existing `profiles/*/profile.cfg`.
    /// The first time a file is touched a copy is kept next to it as `profile.cfg.steppe-orig`.
    @discardableResult
    public static func apply(resolution: Resolution, profilesDir: URL) throws -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: profilesDir.path) else { return outcome }
        for name in names.sorted() {
            let cfg = profilesDir.appendingPathComponent(name).appendingPathComponent("profile.cfg")
            guard fm.fileExists(atPath: cfg.path) else { continue }
            let data = try Data(contentsOf: cfg)
            // Latin-1 preserves every original byte; only ASCII resolution digits change.
            guard let text = String(data: data, encoding: .isoLatin1) else {
                outcome.skipped.append(name)
                continue
            }
            guard let updated = ProfileConfig.settingScreenResolution(resolution, in: text) else {
                outcome.skipped.append(name)
                continue
            }
            if updated == text {
                outcome.unchanged.append(name)
                continue
            }
            let backup = cfg.appendingPathExtension("steppe-orig")
            if !fm.fileExists(atPath: backup.path) { try data.write(to: backup) }
            try updated.data(using: .isoLatin1)!.write(to: cfg, options: .atomic)
            outcome.updated.append(name)
        }
        return outcome
    }
}
