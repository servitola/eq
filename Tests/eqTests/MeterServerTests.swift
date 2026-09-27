import XCTest
@testable import eq

final class MeterServerTests: XCTestCase {
    private var dir: URL!
    private var socketURL: URL { dir.appendingPathComponent("m.sock") }
    private let queue = DispatchQueue(label: "meter-test")
    private var changes: [Int] = []
    private let changesLock = NSLock()

    override func setUp() {
        // sockaddr_un caps the path near 104 bytes; NSTemporaryDirectory is too long for that.
        dir = URL(fileURLWithPath: "/tmp/eq-meter-\(getpid())-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeServer() -> MeterServer {
        MeterServer(socketURL: socketURL, queue: queue, tick: 0.01,
                    source: { MeterFrameTests.sample },
                    onClientsChanged: { [weak self] n in
                        self?.changesLock.lock(); self?.changes.append(n); self?.changesLock.unlock()
                    })
    }

    private func observedChanges() -> [Int] {
        changesLock.lock(); defer { changesLock.unlock() }
        return changes
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { close(fd); throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    func testStreamsLinesWhileAClientListens() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let fd = try connect()

        var received = Data()
        let deadline = Date().addingTimeInterval(0.3)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline, received.filter({ $0 == UInt8(ascii: "\n") }).count < 3 {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { received.append(contentsOf: buffer[0..<n]) }
        }
        let lines = received.split(separator: UInt8(ascii: "\n"))
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        XCTAssertEqual(try JSONDecoder().decode(MeterFrame.self, from: Data(lines[0])), MeterFrameTests.sample)
        XCTAssertEqual(queue.sync { server.clients }, 1)
        XCTAssertEqual(observedChanges(), [1])

        close(fd)
        XCTAssertTrue(waitUntil(0.2) { queue.sync { server.clients } == 0 })
        XCTAssertTrue(waitUntil(0.2) { observedChanges() == [1, 0] }, "\(observedChanges())")
    }

    func testStalePathIsReplaced() throws {
        try Data("stale".utf8).write(to: socketURL)
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let fd = try connect()
        close(fd)
    }

    func testStopRemovesSocketFile() throws {
        let server = makeServer()
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        queue.sync { server.stop() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testOverlongPathThrows() {
        let long = dir.appendingPathComponent(String(repeating: "x", count: 120))
        let server = MeterServer(socketURL: long, queue: queue, source: { MeterFrameTests.sample }, onClientsChanged: { _ in })
        XCTAssertThrowsError(try server.start())
    }
}
