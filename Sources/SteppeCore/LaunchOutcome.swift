import Foundation

public enum LaunchOutcome: Equatable, Sendable {
    case normal
    case crashSignature(Resolution)
    case earlyExit

    public static let earlyExitThreshold: TimeInterval = 15

    public static func classify(
        duration: TimeInterval,
        logTail: String,
        resolution: Resolution,
        profile: GameProfile = .cossacks3
    ) -> LaunchOutcome {
        guard duration < earlyExitThreshold else { return .normal }
        let lower = logTail.lowercased()
        if profile.crashSignatures.contains(where: { lower.contains($0) }) {
            return .crashSignature(resolution)
        }
        return .earlyExit
    }

    public var userNote: String? {
        userNote(for: .cossacks3)
    }

    public func userNote(for profile: GameProfile) -> String? {
        switch self {
        case .normal:
            return nil
        case .crashSignature(let r):
            return L("%@ closed unexpectedly at %@. Try another resolution preset or Settings → Repair.", profile.displayName, r.description)
        case .earlyExit:
            return L("%@ closed right after starting. If this keeps happening, use Settings → Export Diagnostics.", profile.displayName)
        }
    }
}
