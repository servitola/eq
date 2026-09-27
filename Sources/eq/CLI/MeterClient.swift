import Foundation

/// Blocking reader for the daemon's meter socket. One line per read; `lines` never allocates
/// beyond the current partial line, since a stream runs for as long as the terminal is open.
final class MeterClient {
    enum Error: Swift.Error { case notServing }

    private let socketURL: URL
    private var fd: Int32 = -1

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
        while true {
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

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}
