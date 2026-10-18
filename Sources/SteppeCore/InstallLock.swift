import Darwin
import Foundation

/// Cross-process lock for one install folder, so two copies of Steppe (or the app and `steppe-cli`)
/// never modify the same prefix, downloads or engine at the same time. Released when the object is freed
/// or the process exits.
public final class InstallLock {
    private var descriptor: Int32

    /// Returns `nil` if another process holds the lock.
    public init?(root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(".steppe.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
