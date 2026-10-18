import Foundation

/// Removes personal data from text that may be shared in bug reports.
public enum Redaction {
    public static func redact(_ text: String, homeDirectory: String = NSHomeDirectory(), userName: String = NSUserName()) -> String {
        var result = text
        if !homeDirectory.isEmpty, homeDirectory != "/" {
            result = result.replacingOccurrences(of: homeDirectory, with: "~")
        }
        if userName.count >= 3 {
            result = result.replacingOccurrences(of: userName, with: "<user>")
        }
        let patterns: [(String, String)] = [
            // SteamID64
            (#"\b7656119\d{10}\b"#, "<steamid>"),
            // e-mail addresses
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
            // Steam Guard / login tokens that sometimes appear in vdf dumps
            (#"(?i)(token|password|secret)\s*[=:]\s*\S+"#, "$1=<redacted>"),
            // IPv4 addresses
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>"),
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
