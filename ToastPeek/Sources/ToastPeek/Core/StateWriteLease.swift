import Foundation
import Darwin

/// Held for the whole read/modify/write session, not just one atomic rename.
final class StateWriteLease {
    private let descriptor: Int32
    let acquired: Bool

    init(url: URL) {
        descriptor = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        acquired = descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    deinit {
        if descriptor >= 0 {
            if acquired { _ = flock(descriptor, LOCK_UN) }
            _ = Darwin.close(descriptor)
        }
    }
}

/// The writer queue publishes its receipt here so quit can await disk I/O
/// without waiting for a callback on the blocked main actor.
// Every access to stored is protected by lock.
final class StateWriteReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (revision: Int, result: Result<Void, Error>, replacedBackup: Bool, rotatedBackup: Bool)?

    func publish(revision: Int, result: Result<Void, Error>, replacedBackup: Bool, rotatedBackup: Bool) {
        lock.lock(); defer { lock.unlock() }
        stored = (revision, result, replacedBackup, rotatedBackup)
    }

    func read() -> (revision: Int, result: Result<Void, Error>, replacedBackup: Bool, rotatedBackup: Bool)? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
