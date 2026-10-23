import Foundation

public enum Archive {
    /// Extracts a `.tar.xz` with the system `bsdtar`. Absolute paths and `..` components are rejected by default.
    public static func extract(_ archive: URL, to directory: URL, members: [String] = []) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var args = ["-xJf", archive.path, "-C", directory.path]
        args.append(contentsOf: members)
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/tar"), arguments: args, timeout: 900)
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", directory.path], timeout: 30)
    }
}
