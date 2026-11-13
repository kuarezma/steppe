import Foundation

/// Game identity and isolated storage. A definition is not a compatibility claim.
/// The app still exposes only Cossacks 3 until another game passes the acceptance matrix.
public struct GameDefinition: Equatable, Sendable {
    public enum Integration: Equatable, Sendable { case none, cossacks3 }
    public enum DefinitionError: Error { case invalidIdentity, invalidRelativePath }

    public let id: String
    public let displayName: String
    public let steamAppID: Int
    public let executableName: String
    public let documentsRelativePath: String?
    public let profilesRelativePath: String?
    public let integration: Integration

    /// New games start without Cossacks-specific patches or configuration writers.
    public init(id: String, displayName: String, steamAppID: Int, executableName: String,
                documentsRelativePath: String? = nil, profilesRelativePath: String? = nil) throws {
        guard !id.isEmpty, id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, steamAppID > 0 else {
            throw DefinitionError.invalidIdentity
        }
        guard Self.safePath(executableName), !executableName.contains("/"),
              executableName.lowercased().hasSuffix(".exe"),
              documentsRelativePath.map(Self.safePath) ?? true,
              profilesRelativePath.map(Self.safePath) ?? true else { throw DefinitionError.invalidRelativePath }
        self.id = id
        self.displayName = displayName
        self.steamAppID = steamAppID
        self.executableName = executableName
        self.documentsRelativePath = documentsRelativePath
        self.profilesRelativePath = profilesRelativePath
        self.integration = .none
    }

    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\") && !path.contains(":") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private init() {
        id = "cossacks3"
        displayName = "Cossacks 3"
        steamAppID = 333_420
        executableName = "cossacks.exe"
        documentsRelativePath = "Documents/cossacks"
        profilesRelativePath = "Documents/cossacks/profiles"
        integration = .cossacks3
    }

    public static let cossacks3 = GameDefinition()
}
