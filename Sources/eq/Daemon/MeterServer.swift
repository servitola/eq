import Foundation

/// JSON-lines meter feed on a Unix socket; clients may send back newline-delimited requests. Every source, timer and fd is touched only on `queue`,
/// except `start()`, which runs before any source is resumed.
final class MeterServer {
    enum Failure: Error { case pathTooLong(String), posix(String, Int32) }

    private let socketURL: URL
    private let queue: DispatchQueue
    private let tick: TimeInterval
    private let source: () -> MeterFrame
    private let onClientsChanged: (Int) -> Void
    // Returns whether the range was accepted; nil clears. The sender of an accepted range owns it.
    private let onSolo: (SoloRange?) -> Bool
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientFDs: [Int32] = []
    private var readSources: [Int32: DispatchSourceRead] = [:]
    private var timer: DispatchSourceTimer?
    private var didLogEncodeFailure = false
    private var didLogBadRequest = false
    private var pendingInput: [Int32: [UInt8]] = [:]
    // Clients whose current line already overflowed; bytes are skipped up to its newline.
    private var discarding: Set<Int32> = []
    private var soloOwner: Int32?

    static let maxRequestLine = 1024

    private(set) var clients = 0

    init(socketURL: URL, queue: DispatchQueue, tick: TimeInterval = 1.0 / 30,
         source: @escaping () -> MeterFrame, onClientsChanged: @escaping (Int) -> Void,
         onSolo: @escaping (SoloRange?) -> Bool = { _ in false }) {
        self.socketURL = socketURL
        self.queue = queue
        self.tick = tick
        self.source = source
        self.onClientsChanged = onClientsChanged
        self.onSolo = onSolo
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
            // Readable is also how a silent disconnect (EOF) is noticed before the next write fails.
            let reads = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reads.setEventHandler { [weak self] in self?.drain(fd) }
            reads.setCancelHandler { close(fd) }
            reads.resume()
            readSources[fd] = reads
            clientsChanged()
        }
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: Self.maxRequestLine)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                receive(fd, buffer[0..<n])
                continue
            }
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            drop(fd, notify: true)
            return
        }
    }

    private func receive(_ fd: Int32, _ bytes: ArraySlice<UInt8>) {
        var input = pendingInput[fd, default: []]
        input.append(contentsOf: bytes)
        while let newline = input.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Array(input[..<newline])
            input.removeSubrange(...newline)
            if discarding.remove(fd) != nil { continue }
            handle(line, from: fd)
        }
        if input.count > Self.maxRequestLine {
            input.removeAll()
            if discarding.insert(fd).inserted { badRequest() }
        }
        pendingInput[fd] = input
    }

    private func handle(_ line: [UInt8], from fd: Int32) {
        guard line.count <= Self.maxRequestLine,
              let request = try? JSONDecoder().decode(SoloRequest.self, from: Data(line)) else {
            badRequest()
            return
        }
        if let range = request.solo {
            if onSolo(range) { soloOwner = fd }
        } else {
            soloOwner = nil
            _ = onSolo(nil)
        }
    }

    private func badRequest() {
        guard !didLogBadRequest else { return }
        didLogBadRequest = true
        Log.write("meter: ignoring a malformed client request")
    }

    private func drop(_ fd: Int32, notify: Bool) {
        guard let index = clientFDs.firstIndex(of: fd) else { return }
        clientFDs.remove(at: index)
        readSources.removeValue(forKey: fd)?.cancel()
        pendingInput.removeValue(forKey: fd)
        discarding.remove(fd)
        // Cleared before the fd number can be reused by the next accept.
        if soloOwner == fd {
            soloOwner = nil
            _ = onSolo(nil)
        }
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
        let line: Data
        do {
            line = try MeterFrame.encodeLine(source())
        } catch {
            if !didLogEncodeFailure {
                Log.write("meter: frame not encodable")
                didLogEncodeFailure = true
            }
            return
        }
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

/// `{"solo":{"low":L,"high":H}}` or `{"solo":null}`; a line without the key is malformed.
private struct SoloRequest: Decodable {
    let solo: SoloRange?

    private enum Keys: String, CodingKey { case solo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard c.contains(.solo) else {
            throw DecodingError.keyNotFound(Keys.solo, .init(codingPath: [], debugDescription: "no solo"))
        }
        solo = try c.decodeIfPresent(SoloRange.self, forKey: .solo)
    }
}
