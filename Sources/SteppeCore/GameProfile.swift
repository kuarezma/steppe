import Foundation

/// Game-specific constants separated from the generic Steppe Wine/Steam runner.
public struct GameProfile: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let prefixDirectoryName: String
    public let executableName: String
    public let steamAppID: Int
    public let documentsSubpath: String
    public let crashSignatures: [String]
    public let minimumFreeBytes: Int64

    public init(
        id: String,
        displayName: String,
        prefixDirectoryName: String,
        executableName: String,
        steamAppID: Int,
        documentsSubpath: String,
        crashSignatures: [String],
        minimumFreeBytes: Int64
    ) {
        self.id = id
        self.displayName = displayName
        self.prefixDirectoryName = prefixDirectoryName
        self.executableName = executableName
        self.steamAppID = steamAppID
        self.documentsSubpath = documentsSubpath
        self.crashSignatures = crashSignatures
        self.minimumFreeBytes = minimumFreeBytes
    }

    public static let cossacks3 = GameProfile(
        id: "cossacks3",
        displayName: "Cossacks 3",
        prefixDirectoryName: "cossacks3",
        executableName: "cossacks.exe",
        steamAppID: 333_420,
        documentsSubpath: "Documents/cossacks",
        crashSignatures: [
            "00427a2b",
            "access violation",
            "unhandled page fault",
            "unhandled exception",
        ],
        minimumFreeBytes: 8_000_000_000
    )
}
