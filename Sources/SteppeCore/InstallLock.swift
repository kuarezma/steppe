import Darwin
import Foundation

public enum LockFailure: Error, Equatable, Sendable {
    case alreadyHeld
    case ioError(Int32)
    case directoryError(String)
}

/// Cross-process lock for one install folder, so two copies of Steppe (or the app and `steppe-cli`)
/// never modify the same prefix, downloads or engine at the same time. Released when the object is freed
/// or the process exits.
public final class InstallLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Acquires an exclusive non-blocking lock, distinguishing lock contention from filesystem I/O failures.
    public static func acquire(root: URL) -> Result<InstallLock, LockFailure> {
        switch openLockedDescriptor(root: root) {
        case .success(let fd):
            return .success(InstallLock(descriptor: fd))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private static func openLockedDescriptor(root: URL) -> Result<Int32, LockFailure> {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return .failure(.directoryError(error.localizedDescription))
        }
        let path = root.appendingPathComponent(".steppe.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return .failure(.ioError(errno)) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK || err == EAGAIN {
                return .failure(.alreadyHeld)
            }
            return .failure(.ioError(err))
        }
        return .success(fd)
    }

    /// Returns `nil` if another process holds the lock or the lock file cannot be opened.
    public convenience init?(root: URL) {
        guard case .success(let fd) = Self.openLockedDescriptor(root: root) else { return nil }
        self.init(descriptor: fd)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
