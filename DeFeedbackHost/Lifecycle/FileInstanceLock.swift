//
//  FileInstanceLock.swift
//  DeFeedbackHost
//
//  `flock(2)` implementation of `InstanceLock` (contract: InstanceLock.swift).
//  The lock file holds the holder's PID; its modification time is the heartbeat.
//
import Foundation

final class FileInstanceLock: InstanceLock {

    private let url: URL
    private var descriptor: Int32 = -1

    /// Lock file inside `directory` (created if needed).
    init(directory: URL, name: String = "instance.lock") {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appending(path: name)
    }

    /// Default location, keyed on the bundle ID so it is independent of where the app lives.
    static func standard(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.eklynx.sound.DeFeedbackHost") -> FileInstanceLock {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileInstanceLock(directory: support.appending(path: bundleIdentifier))
    }

    deinit { release() }

    func tryAcquire() -> Bool {
        if descriptor >= 0 { return true }

        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return true }   // fail open, see contract

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }

        descriptor = fd
        let pid = "\(getpid())"
        ftruncate(fd, 0)
        _ = pid.withCString { pwrite(fd, $0, strlen($0), 0) }
        heartbeat()
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    func holderPID() -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        return pid
    }

    func heartbeat() {
        guard descriptor >= 0 else { return }
        futimes(descriptor, nil)
    }

    func holderHeartbeatAge() -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return max(0, Date().timeIntervalSince(modified))
    }
}
