import Foundation

/// Blocking reader for the daemon's meter socket. One line per read; `lines` never allocates
/// beyond the current partial line, since a stream runs for as long as the terminal is open.
final class MeterClient {
    enum Error: Swift.Error { case notServing }

    private let socketURL: URL
    private var fd: Int32 = -1
    /// Also waited on by `lines`: when it has something to read, or nothing arrived for `idle`
    /// seconds, `handle` gets an empty line, so keys work while the daemon sends no frames.
    var input: Int32?
    static let idle = 0.1

    init(socketURL: URL) { self.socketURL = socketURL }

    func connect() throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw Error.notServing }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketURL.path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(sock)
            throw Error.notServing
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(sock)
            throw Error.notServing
        }
        // A write after the daemon went away would otherwise raise SIGPIPE and kill the watch
        // before it could put the terminal back.
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        fd = sock
    }

    /// Stops on EOF, on `handle` returning false, or once `maxLines` lines were delivered — the
    /// last only exists so tests can end a stream that otherwise runs until Ctrl-C. Returns
    /// true only for the EOF case, so a caller can tell a closed daemon socket apart from a
    /// voluntary stop.
    @discardableResult
    func lines(maxLines: Int? = nil, handle: (String) -> Bool) -> Bool {
        guard fd >= 0 else { return false }
        var pending = Data()
        var delivered = 0
        var chunk = [UInt8](repeating: 0, count: 4096)
        var input = self.input
        while true {
            if let watched = input {
                var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: watched, events: Int16(POLLIN), revents: 0)]
                let ready = poll(&fds, 2, Int32(Self.idle * 1000))
                if ready < 0 {
                    // A signal (a resize, a resume) woke the wait: the caller redraws now, not at the next frame.
                    if errno == EINTR { guard handle("") else { return false } } else { input = nil }
                    continue
                }
                // A hung-up terminal stays readable forever; stop waiting on it rather than spin.
                if fds[1].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { input = nil }
                if fds[0].revents == 0 {
                    guard handle("") else { return false }
                    continue
                }
            }
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return true }
            pending.append(contentsOf: chunk[0..<n])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                guard handle(line) else { return false }
                delivered += 1
                if let maxLines, delivered >= maxLines { return false }
            }
        }
    }

    /// One request line to the daemon; the newline is what frames it on the other side.
    func send(_ line: String) throws {
        guard fd >= 0 else { throw Error.notServing }
        let bytes = Array(line.utf8) + (line.hasSuffix("\n") ? [] : [UInt8(ascii: "\n")])
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw Error.notServing }
            offset += n
        }
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}
