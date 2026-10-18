import Foundation

public enum WinePatchError: Error, LocalizedError, Equatable {
    case fileMissing(String)
    case unexpectedOriginal(String)
    case bytesDiffer(offset: Int)
    case patchedHashMismatch(String)
    case signingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing: return L("The Wine engine is incomplete. Please try again.")
        case .unexpectedOriginal: return L("The Wine engine is not the version Steppe was built for.")
        case .bytesDiffer: return L("The Wine engine is not the version Steppe was built for.")
        case .patchedHashMismatch: return L("Preparing the Wine engine failed its safety check.")
        case .signingFailed: return L("Preparing the Wine engine failed. Please try again.")
        }
    }
}

/// Applies Steppe's small binary patches to Wine's macOS driver and re-signs it ad hoc.
///
/// Every step is verified by SHA-256 so a wrong or tampered engine is rejected instead of patched blindly.
public enum WinePatcher {
    private static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")

    public static func apply(engineRoot: URL, patch: RuntimeManifest.WinemacPatch) async throws {
        let target = engineRoot.appendingPathComponent(patch.relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw WinePatchError.fileMissing(patch.relativePath)
        }
        let original = try Hashing.sha256(of: target)
        guard original == patch.originalSHA256 else { throw WinePatchError.unexpectedOriginal(original) }

        let patched = try applyBytes(try Data(contentsOf: target), patches: patch.patches)

        let work = target.deletingLastPathComponent().appendingPathComponent(".winemac-patching-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try patched.write(to: work)

        // The original code signature no longer matches; replace it with an ad-hoc one.
        try await sign(arguments: ["--remove-signature", work.path])
        try await sign(arguments: ["--force", "--sign", "-", work.path])
        try await sign(arguments: ["--verify", "--strict", work.path])

        // Content check: a signature round trip strips the file back to a canonical form with a known hash.
        let probe = work.appendingPathExtension("probe")
        defer { try? FileManager.default.removeItem(at: probe) }
        try FileManager.default.copyItem(at: work, to: probe)
        try await sign(arguments: ["--remove-signature", probe.path])
        let canonical = try Hashing.sha256(of: probe)
        guard canonical == patch.patchedUnsignedSHA256 else { throw WinePatchError.patchedHashMismatch(canonical) }

        // Preserve the executable bit and swap in the patched file atomically.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.path)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: work)

        // Sign under the final name so the code-signature identifier matches the file.
        try await sign(arguments: ["--force", "--sign", "-", target.path])
    }

    /// Pure byte-level step, separated for unit tests.
    public static func applyBytes(_ data: Data, patches: [RuntimeManifest.BytePatch]) throws -> Data {
        var bytes = [UInt8](data)
        for patch in patches {
            let end = patch.offset + patch.expected.count
            guard patch.expected.count == patch.replacement.count,
                  patch.offset >= 0, end <= bytes.count,
                  Array(bytes[patch.offset..<end]) == patch.expected else {
                throw WinePatchError.bytesDiffer(offset: patch.offset)
            }
            bytes.replaceSubrange(patch.offset..<end, with: patch.replacement)
        }
        return Data(bytes)
    }

    /// Cheap integrity check: the patched byte ranges are in place and the signature validates.
    public static func isPatched(engineRoot: URL, patch: RuntimeManifest.WinemacPatch) async -> Bool {
        let target = engineRoot.appendingPathComponent(patch.relativePath)
        guard let data = try? Data(contentsOf: target, options: .mappedIfSafe) else { return false }
        for p in patch.patches {
            let end = p.offset + p.replacement.count
            guard end <= data.count, Array(data[p.offset..<end]) == p.replacement else { return false }
        }
        let verify = try? await ProcessRunner.run(codesign, arguments: ["--verify", target.path], timeout: 30)
        return verify?.succeeded == true
    }

    private static func sign(arguments: [String]) async throws {
        do {
            try await ProcessRunner.runChecked(codesign, arguments: arguments, timeout: 60)
        } catch {
            throw WinePatchError.signingFailed(error.localizedDescription)
        }
    }
}
