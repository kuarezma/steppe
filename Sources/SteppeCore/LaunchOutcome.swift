import Foundation

public enum LaunchOutcome: Equatable, Sendable {
    case normal
    case crashSignature(Resolution)
    case earlyExit

    public static let earlyExitThreshold: TimeInterval = 15

    public static func classify(duration: TimeInterval, logTail: String, resolution: Resolution) -> LaunchOutcome {
        guard duration < earlyExitThreshold else { return .normal }
        let lower = logTail.lowercased()
        let signatures = ["00427a2b", "access violation", "unhandled page fault", "unhandled exception"]
        if signatures.contains(where: { lower.contains($0) }) {
            return .crashSignature(resolution)
        }
        return .earlyExit
    }

    public var userNote: String? {
        switch self {
        case .normal:
            return nil
        case .crashSignature(let r):
            return L("Cossacks 3 closed unexpectedly at %@. Try another resolution preset or Settings → Repair.", r.description)
        case .earlyExit:
            return L("Cossacks 3 closed right after starting. If this keeps happening, use Settings → Export Diagnostics.")
        }
    }
}
