import AVFoundation
import Foundation

public enum MicrophoneStatus: String, Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined

    public var localizedLabel: String {
        switch self {
        case .authorized: return L("Allowed")
        case .denied, .restricted: return L("Denied")
        case .notDetermined: return L("Not requested yet")
        }
    }
}

/// Manages macOS TCC microphone authorization for Steppe and its child Wine/Steam processes.
///
/// Because Steppe is signed ad hoc (`-`) by default, updating the app changes its Mach-O CDHash.
/// If macOS TCC holds an older CDHash record (or a denied record from an earlier build that lacked
/// `NSMicrophoneUsageDescription` and `com.apple.security.device.audio-input`), `tccd` silently blocks
/// Wine (`winecoreaudio.drv`) when Steam opens the MacBook microphone.
///
/// `MicrophonePermission` detects binary changes, clears stale TCC entries with `tccutil`, and requests
/// microphone access from the host app *before* Wine starts so CoreAudio sees a settled authorization state.
public enum MicrophonePermission {
    public static let bundleIdentifier = "io.github.kuarezma.steppe"
    private static let binaryHashDefaultsKey = "steppeMicrophoneBinarySHA256"
    private static let tccutil = URL(fileURLWithPath: "/usr/bin/tccutil")

    public static func status() -> MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Ensures the host app's TCC microphone record is valid for the current binary and requests access if needed
    /// before Steam or the game starts.
    @discardableResult
    public static func ensureAccessForSteam(defaults: UserDefaults = .standard) async -> MicrophoneStatus {
        guard isRunningAsAppBundle else { return status() }
        await resetIfBinaryChanged(defaults: defaults)

        let current = status()
        if current == .authorized { return .authorized }

        if current == .notDetermined {
            let started = Date()
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted {
                Log.shared.info("Microphone access granted")
                return .authorized
            }
            // When tccd rejects an ad-hoc CDHash mismatch without showing a prompt, requestAccess returns false
            // almost instantaneously (< 150 ms). Resetting the TCC entry once allows macOS to show the real prompt.
            if Date().timeIntervalSince(started) < 0.15 {
                Log.shared.info("Microphone prompt was suppressed by a stale TCC signature; resetting and retrying")
                await resetTCC()
                let retryGranted = await AVCaptureDevice.requestAccess(for: .audio)
                Log.shared.info("Microphone access after TCC reset: \(retryGranted)")
            }
        }
        return status()
    }

    /// Resets the TCC microphone entry for Steppe and asks macOS to prompt the user again.
    @discardableResult
    public static func resetAndRequestAccess(defaults: UserDefaults = .standard) async -> MicrophoneStatus {
        await resetTCC()
        if let hash = currentExecutableSHA256() {
            defaults.set(hash, forKey: binaryHashDefaultsKey)
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        let updated = status()
        Log.shared.info("Microphone permission after manual reset: \(updated.rawValue)")
        return updated
    }

    private static var isRunningAsAppBundle: Bool {
        Bundle.main.bundleIdentifier == bundleIdentifier && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private static func currentExecutableSHA256() -> String? {
        guard let execURL = Bundle.main.executableURL else { return nil }
        return try? Hashing.sha256(of: execURL)
    }

    private static func resetIfBinaryChanged(defaults: UserDefaults) async {
        guard let currentHash = currentExecutableSHA256() else { return }
        let storedHash = defaults.string(forKey: binaryHashDefaultsKey)
        guard storedHash != currentHash else { return }
        Log.shared.info("App executable changed (or first microphone setup); refreshing TCC microphone state")
        await resetTCC()
        defaults.set(currentHash, forKey: binaryHashDefaultsKey)
    }

    public static func resetTCC() async {
        _ = try? await ProcessRunner.run(
            tccutil,
            arguments: ["reset", "Microphone", bundleIdentifier],
            timeout: 10
        )
    }
}
