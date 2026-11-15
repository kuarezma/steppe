import Foundation

/// Removes personal data from text that may be shared in bug reports.
public enum Redaction {
    private static let compiledRules: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // Other macOS home paths not already collapsed to ~
            (#"/Users/[^/\s\"']+"#, "/Users/<user>"),
            // External drive volume labels (allows spaces and apostrophes inside mounted volume names)
            (#"/Volumes/(?:[^/\r\n\"]+(?=/|\"|\r|\n|$)|[^/\s\"']+)"#, "/Volumes/<volume>"),
            // SteamID64
            (#"\b7656119\d{10}\b"#, "<steamid>"),
            // e-mail addresses
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
            // Steam Guard / login tokens that sometimes appear in vdf dumps
            (#"(?i)(token|password|secret)\s*[=:]\s*\S+"#, "$1=<redacted>"),
            // Strict IPv4 addresses (rejects out-of-range octets and multi-dot version numbers)
            (#"(?<![A-Za-z0-9_.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?!\d|\.\d)"#, "<ip>"),
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, template)
        }
    }()

    public static func redact(_ text: String, homeDirectory: String = NSHomeDirectory(), userName: String = NSUserName()) -> String {
        var result = text
        if !homeDirectory.isEmpty, homeDirectory != "/" {
            result = result.replacingOccurrences(of: homeDirectory, with: "~")
        }
        for (regex, template) in compiledRules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        if userName.count >= 3 {
            let escaped = NSRegularExpression.escapedPattern(for: userName)
            if let userRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])"# + escaped + #"(?![A-Za-z0-9_])"#) {
                let range = NSRange(result.startIndex..., in: result)
                result = userRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "<user>")
            }
        }
        return result
    }
}
