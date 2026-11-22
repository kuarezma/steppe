import Foundation

/// Game-specific constants separated from the generic Steppe Wine/Steam runner.
public struct GameProfile: Sendable, Equatable {
    public enum Integration: Equatable, Sendable {
        case none
        case cossacks3
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidIdentity
        case invalidRelativePath
    }

    public let id: String
    public let displayName: String
    public let prefixDirectoryName: String
    public let executableName: String
    public let steamAppID: Int
    public let documentsSubpath: String?
    public let profilesSubpath: String?
    public let integration: Integration
    public let crashSignatures: [String]
    public let minimumFreeBytes: Int64

    /// Free space required after the Wine engine is already on disk.
    public var requiredFreeBytesAfterEngine: Int64 { minimumFreeBytes + 3_000_000_000 }

    /// Free space required before downloading the Wine engine and the game.
    public var requiredFreeBytesInitial: Int64 { minimumFreeBytes + 8_000_000_000 }

    public init(
        id: String,
        displayName: String,
        prefixDirectoryName: String,
        executableName: String,
        steamAppID: Int,
        documentsSubpath: String?,
        profilesSubpath: String? = nil,
        integration: Integration = .none,
        crashSignatures: [String],
        minimumFreeBytes: Int64
    ) {
        self.id = id
        self.displayName = displayName
        self.prefixDirectoryName = prefixDirectoryName
        self.executableName = executableName
        self.steamAppID = steamAppID
        self.documentsSubpath = documentsSubpath
        self.profilesSubpath = profilesSubpath
        self.integration = integration
        self.crashSignatures = crashSignatures
        self.minimumFreeBytes = minimumFreeBytes
    }

    /// Validates candidate game definitions safely without inheriting Cossacks-specific injection/tuning.
    public static func validated(
        id: String,
        displayName: String,
        steamAppID: Int,
        executableName: String,
        documentsSubpath: String? = nil,
        profilesSubpath: String? = nil,
        crashSignatures: [String] = [],
        minimumFreeBytes: Int64 = 8_000_000_000
    ) throws -> GameProfile {
        guard !id.isEmpty,
              id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              steamAppID > 0 else {
            throw ValidationError.invalidIdentity
        }
        guard isSafeRelativePath(executableName),
              !executableName.contains("/"),
              executableName.lowercased().hasSuffix(".exe"),
              documentsSubpath.map(isSafeRelativePath) ?? true,
              profilesSubpath.map(isSafeRelativePath) ?? true else {
            throw ValidationError.invalidRelativePath
        }
        return GameProfile(
            id: id,
            displayName: displayName,
            prefixDirectoryName: id,
            executableName: executableName,
            steamAppID: steamAppID,
            documentsSubpath: documentsSubpath,
            profilesSubpath: profilesSubpath,
            integration: .none,
            crashSignatures: crashSignatures,
            minimumFreeBytes: minimumFreeBytes
        )
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.contains("\\")
            && !path.contains(":")
            && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static let cossacks3 = GameProfile(
        id: "cossacks3",
        displayName: "Cossacks 3",
        prefixDirectoryName: "cossacks3",
        executableName: "cossacks.exe",
        steamAppID: 333_420,
        documentsSubpath: "Documents/cossacks",
        profilesSubpath: "Documents/cossacks/profiles",
        integration: .cossacks3,
        crashSignatures: [
            "00427a2b",
            "access violation",
            "unhandled page fault",
            "unhandled exception",
        ],
        minimumFreeBytes: 8_000_000_000
    )
}
