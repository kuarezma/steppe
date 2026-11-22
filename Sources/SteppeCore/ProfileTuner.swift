import Foundation

/// Edits the game's `profile.cfg` (a nested `struct.begin` / `struct.end` text format).
///
/// Only the `ScreenResolution` block (and optionally `UseMultithreadedMode`) is touched; every other byte is preserved.
public enum ProfileConfig {
    public static func screenResolution(in text: String) -> Resolution? {
        guard let span = resolutionSpan(in: text) else { return nil }
        return span.current
    }

    public static func multithreaded(in text: String) -> Bool? {
        guard let (_, value) = multithreadedValueRange(in: text) else { return nil }
        return value
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

    /// Returns the updated text with `UseMultithreadedMode` set, or inserts it inside `Engine` when missing.
    /// Returns `nil` only if the file has no `Engine` block.
    public static func settingMultithreaded(_ enabled: Bool, in text: String) -> String? {
        if let (range, current) = multithreadedValueRange(in: text) {
            if current == enabled { return text }
            var result = text
            result.replaceSubrange(range, with: enabled ? "True" : "False")
            return result
        }
        guard let engineStart = text.range(of: #"Engine\s*:\s*struct\.begin"#, options: .regularExpression) else { return nil }
        guard let engineEnd = matchingStructEndStart(in: text, after: engineStart.upperBound) else { return nil }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var insertion = "      UseMultithreadedMode = \(enabled ? "True" : "False")\(newline)"
        if engineEnd > text.startIndex && !text[text.index(before: engineEnd)].isNewline {
            insertion = newline + insertion
        }
        var result = text
        result.insert(contentsOf: insertion, at: engineEnd)
        return result
    }

    private static func matchingStructEndStart(in text: String, after start: String.Index) -> String.Index? {
        var depth = 1
        var cursor = start
        let tokenPattern = #"\bstruct\.(begin|end)\b"#
        while cursor < text.endIndex,
              let match = text.range(of: tokenPattern, options: .regularExpression, range: cursor..<text.endIndex) {
            let token = text[match]
            if token.hasSuffix("begin") {
                depth += 1
            } else {
                depth -= 1
                if depth == 0 {
                    var lineStart = match.lowerBound
                    while lineStart > start {
                        let prev = text.index(before: lineStart)
                        if text[prev].isNewline { break }
                        lineStart = prev
                    }
                    return lineStart
                }
            }
            cursor = match.upperBound
        }
        return nil
    }

    private static func multithreadedValueRange(in text: String) -> (Range<String.Index>, Bool)? {
        guard let engineStart = text.range(of: #"Engine\s*:\s*struct\.begin"#, options: .regularExpression) else { return nil }
        guard let match = text.range(of: #"\bUseMultithreadedMode\s*=\s*(True|False)\b"#, options: [.regularExpression, .caseInsensitive], range: engineStart.upperBound..<text.endIndex) else { return nil }
        let line = text[match]
        guard let valRange = line.range(of: #"(True|False)$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return (valRange, line[valRange].lowercased() == "true")
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

    /// Writes `resolution` (and optionally `UseMultithreadedMode`) into every existing `profiles/*/profile.cfg`.
    /// The first time a file is touched a copy is kept next to it as `profile.cfg.steppe-orig`.
    @discardableResult
    public static func apply(resolution: Resolution, multithreaded: Bool? = nil, profilesDir: URL) throws -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: profilesDir.path) else { return outcome }
        for name in names.sorted() {
            let cfg = profilesDir.appendingPathComponent(name).appendingPathComponent("profile.cfg")
            guard fm.fileExists(atPath: cfg.path) else { continue }
            let data = try Data(contentsOf: cfg)
            // Latin-1 preserves every original byte; only ASCII resolution/flag bytes change.
            guard let text = String(data: data, encoding: .isoLatin1) else {
                outcome.skipped.append(name)
                continue
            }
            guard var updated = ProfileConfig.settingScreenResolution(resolution, in: text) else {
                outcome.skipped.append(name)
                continue
            }
            if let multithreaded, let withMT = ProfileConfig.settingMultithreaded(multithreaded, in: updated) {
                updated = withMT
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
