import Foundation

/// Read-only JSON-lines feed on a Unix socket. Every source, timer and fd is touched only on `queue`,
/// except `start()`, which runs before any source is resumed.
final class MeterServer {
    enum Failure: Error { case pathTooLong(String), posix(String, Int32) }

    private let socketURL: URL
    private let queue: DispatchQueue
    private let tick: TimeInterval
    private let source: () -> MeterFrame
    private let onClientsChanged: (Int) -> Void
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientFDs: [Int32] = []
    private var readSources: [Int32: DispatchSourceRead] = [:]
    private var timer: DispatchSourceTimer?

    private(set) var clients = 0

    init(socketURL: URL, queue: DispatchQueue, tick: TimeInterval = 1.0 / 30,
         source: @escaping () -> MeterFrame, onClientsChanged: @escaping (Int) -> Void) {
        self.socketURL = socketURL
        self.queue = queue
        self.tick = tick
        self.source = source
        self.onClientsChanged = onClientsChanged
    }

    func start() throws {
        var addr = sockaddr_un()
        let path = socketURL.path
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.pathTooLong(path) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }

        try? FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A daemon killed with SIGKILL leaves its socket file behind; bind would fail with EADDRINUSE.
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.posix("socket", errno) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw Failure.posix("bind", e) }
        guard listen(fd, 5) == 0 else { let e = errno; close(fd); unlink(path); throw Failure.posix("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let accepts = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        accepts.setEventHandler { [weak self] in self?.acceptAll() }
        // GCD requires the descriptor to stay open until the source's cancel handler runs.
        accepts.setCancelHandler { close(fd) }
        accepts.resume()
        acceptSource = accepts
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for fd in clientFDs { drop(fd, notify: false) }
        guard let accepts = acceptSource else { return }
        accepts.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(socketURL.path)
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            clientFDs.append(fd)
            // Clients never send anything; readable means EOF (or junk we discard), which is how a
            // silent disconnect is noticed before the next write fails.
            let reads = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reads.setEventHandler { [weak self] in self?.drain(fd) }
            reads.setCancelHandler { close(fd) }
            reads.resume()
            readSources[fd] = reads
            clientsChanged()
        }
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { continue }
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            drop(fd, notify: true)
            return
        }
    }

    private func drop(_ fd: Int32, notify: Bool) {
        guard let index = clientFDs.firstIndex(of: fd) else { return }
        clientFDs.remove(at: index)
        readSources.removeValue(forKey: fd)?.cancel()
        if notify { clientsChanged() } else { clients = clientFDs.count }
    }

    private func clientsChanged() {
        clients = clientFDs.count
        if clients > 0, timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.broadcast() }
            t.resume()
            timer = t
        } else if clients == 0 {
            timer?.cancel()
            timer = nil
        }
        onClientsChanged(clients)
    }

    private func broadcast() {
        guard let line = try? MeterFrame.encodeLine(source()) else { return }
        for fd in clientFDs {
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                // EAGAIN: a slow reader's buffer is full; skipping one frame beats blocking the daemon.
                if errno != EAGAIN { drop(fd, notify: true) }
            } else if written < line.count {
                // A short write would glue the next line onto this one's tail for the reader; drop instead.
                drop(fd, notify: true)
            }
        }
    }
}
