import Foundation

/// Looks up a user-visible message in the app bundle's `Localizable.strings`.
/// The English text is the key, so a missing translation falls back to readable English.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
