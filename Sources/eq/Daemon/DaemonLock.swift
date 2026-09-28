import Darwin
import Foundation

/// One daemon per status directory, whatever launched it: two taps on one output would stack
/// their curves. flock goes with the process however it dies, so a crash never leaves it held.
enum DaemonLock {
    enum Outcome: Equatable {
        case acquired(Int32)
        case held(by: Int32?)
        case failed(String)
    }

    static func url(beside statusURL: URL) -> URL {
        statusURL.deletingLastPathComponent().appendingPathComponent("daemon.lock")
    }

    /// O_CLOEXEC: a hook's child would otherwise keep the lock past the daemon's exit.
    static func acquire(_ url: URL) -> Outcome {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failed("cannot open \(url.path) (errno \(errno))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            var buffer = [UInt8](repeating: 0, count: 16)
            let count = pread(fd, &buffer, buffer.count, 0)
            close(fd)
            let holder = count > 0 ? Int32(String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            return busy ? .held(by: holder) : .failed("cannot lock \(url.path) (errno \(errno))")
        }
        let pid = Array("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pwrite(fd, pid, pid.count, 0)
        return .acquired(fd)
    }
}
