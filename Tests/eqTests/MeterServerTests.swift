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

    private var solos: [SoloRange?] = []

    private func makeServer(tick: TimeInterval = 0.01) -> MeterServer {
        MeterServer(socketURL: socketURL, queue: queue, tick: tick,
                    source: { MeterFrameTests.sample },
                    onClientsChanged: { [weak self] n in
                        self?.changesLock.lock(); self?.changes.append(n); self?.changesLock.unlock()
                    },
                    onSolo: { [weak self] range in
                        // Stands in for the daemon's sample-rate clamp, as in call mode refusing air.
                        if let range, range.low >= 10_000 { return false }
                        self?.changesLock.lock(); self?.solos.append(range); self?.changesLock.unlock()
                        return true
                    })
    }

    private func observedSolos() -> [SoloRange?] {
        changesLock.lock(); defer { changesLock.unlock() }
        return solos
    }

    private func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        XCTAssertEqual(write(fd, bytes, bytes.count), bytes.count)
    }

    private static let voice = SoloRange(low: 300, high: 2800)
    private static let bass = SoloRange(low: 40, high: 250)

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

    func testSoloAppliesAndClearsWhenItsOwnerDisconnects() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let fd = try connect()
        send(fd, "{\"solo\":{\"low\":300,\"high\":2800}}\n")
        XCTAssertTrue(waitUntil(0.5) { observedSolos() == [Self.voice] }, "\(observedSolos())")
        close(fd)
        XCTAssertTrue(waitUntil(0.5) { observedSolos() == [Self.voice, nil] }, "\(observedSolos())")
    }

    func testNullClearsAndSplitWritesAreReassembled() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let fd = try connect()
        defer { close(fd) }
        send(fd, "{\"solo\":{\"low\":40,")
        usleep(20_000)
        send(fd, "\"high\":250}}\n{\"solo\":null}\n")
        XCTAssertTrue(waitUntil(0.5) { observedSolos() == [Self.bass, nil] }, "\(observedSolos())")
    }

    func testLastWriterWinsAndOnlyTheOwnerDisconnectClears() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let first = try connect()
        let second = try connect()
        send(first, "{\"solo\":{\"low\":300,\"high\":2800}}\n")
        XCTAssertTrue(waitUntil(0.5) { observedSolos().count == 1 })
        send(second, "{\"solo\":{\"low\":40,\"high\":250}}\n")
        XCTAssertTrue(waitUntil(0.5) { observedSolos().count == 2 })
        close(first)
        XCTAssertTrue(waitUntil(0.5) { queue.sync { server.clients } == 1 })
        XCTAssertEqual(observedSolos(), [Self.voice, Self.bass])
        close(second)
        XCTAssertTrue(waitUntil(0.5) { observedSolos() == [Self.voice, Self.bass, nil] }, "\(observedSolos())")
    }

    func testRefusedRangeDoesNotTakeOwnership() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let owner = try connect()
        defer { close(owner) }
        let other = try connect()
        send(owner, "{\"solo\":{\"low\":300,\"high\":2800}}\n")
        send(other, "{\"solo\":{\"low\":2800,\"high\":300}}\n")
        XCTAssertTrue(waitUntil(0.5) { queue.sync { server.clients } == 2 })
        usleep(50_000)
        close(other)
        XCTAssertTrue(waitUntil(0.5) { queue.sync { server.clients } == 1 })
        XCTAssertEqual(observedSolos(), [Self.voice])
    }

    func testMalformedAndOverlongLinesAreIgnored() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let fd = try connect()
        defer { close(fd) }
        send(fd, "not json\n{\"volume\":3}\n")
        send(fd, "{\"solo\":{\"low\":40,\"high\":250},\"pad\":\"" + String(repeating: "x", count: 2 * MeterServer.maxRequestLine) + "\"}\n")
        send(fd, "{\"solo\":{\"low\":300,\"high\":2800}}\n")
        XCTAssertTrue(waitUntil(0.5) { observedSolos() == [Self.voice] }, "\(observedSolos())")
        XCTAssertEqual(queue.sync { server.clients }, 1)
    }

    func testOutOfBoundsRangesAreIgnoredWithoutCrashing() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let fd = try connect()
        defer { close(fd) }
        for range in [#"{"low":300,"high":1e300}"#, #"{"low":-1e300,"high":300}"#, #"{"low":2800,"high":300}"#,
                      #"{"low":0,"high":0}"#, #"{"low":300,"high":100001}"#] {
            send(fd, #"{"solo":"# + range + "}\n")
        }
        send(fd, "{\"solo\":{\"low\":0,\"high\":100000}}\n")
        XCTAssertTrue(waitUntil(0.5) { observedSolos() == [SoloRange(low: 0, high: 100_000)] }, "\(observedSolos())")
        XCTAssertEqual(queue.sync { server.clients }, 1)
    }

    func testRefusedRangeFromTheOwnerClearsItsSolo() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let fd = try connect()
        defer { close(fd) }
        send(fd, "{\"solo\":{\"low\":300,\"high\":2800}}\n")
        send(fd, "{\"solo\":{\"low\":12000,\"high\":20000}}\n")
        XCTAssertTrue(waitUntil(0.5) { observedSolos() == [Self.voice, nil] }, "\(observedSolos())")
    }

    func testNullFromANonOwnerIsIgnored() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let owner = try connect()
        let other = try connect()
        defer { close(other) }
        send(owner, "{\"solo\":{\"low\":300,\"high\":2800}}\n")
        XCTAssertTrue(waitUntil(0.5) { observedSolos() == [Self.voice] })
        send(other, "{\"solo\":null}\n")
        usleep(50_000)
        XCTAssertEqual(observedSolos(), [Self.voice])
        close(owner)
        XCTAssertTrue(waitUntil(0.5) { observedSolos() == [Self.voice, nil] }, "\(observedSolos())")
    }

    func testClientsBeyondTheCapAreClosed() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let kept = try (0..<MeterServer.maxClients).map { _ in try connect() }
        defer { kept.forEach { close($0) } }
        XCTAssertTrue(waitUntil(0.5) { queue.sync { server.clients } == MeterServer.maxClients })
        let extra = try connect()
        defer { close(extra) }
        var byte: UInt8 = 0
        var closed = false
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, !closed { closed = read(extra, &byte, 1) == 0 }
        XCTAssertTrue(closed, "the ninth client gets EOF")
        XCTAssertEqual(queue.sync { server.clients }, MeterServer.maxClients)

        close(kept[0])
        XCTAssertTrue(waitUntil(0.5) { queue.sync { server.clients } == MeterServer.maxClients - 1 })
        let again = try connect()
        defer { close(again) }
        XCTAssertTrue(waitUntil(0.5) { queue.sync { server.clients } == MeterServer.maxClients })
    }

    private func readLines(_ fd: Int32, count: Int, within timeout: TimeInterval) -> [String] {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, received.filter({ $0 == UInt8(ascii: "\n") }).count < count {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { received.append(contentsOf: buffer[0..<n]) }
        }
        return received.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
    }

    private func kind(_ line: String) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["event"] as? String
    }

    func testSubscribingNeitherMetersNorTicks() throws {
        var frames = 0
        let server = MeterServer(socketURL: socketURL, queue: queue, tick: 0.01,
                                 source: { frames += 1; return MeterFrameTests.sample },
                                 onClientsChanged: { [weak self] n in
                                     self?.changesLock.lock(); self?.changes.append(n); self?.changesLock.unlock()
                                 },
                                 hello: { .daemon(state: .bypassed, version: "9", error: nil) })
        try server.start()
        defer { queue.sync { server.stop() } }
        let fd = try connect()
        defer { close(fd) }
        send(fd, "{\"subscribe\":\"events\"}\n")
        let hello = readLines(fd, count: 1, within: 0.3)
        XCTAssertEqual(hello.count, 1)
        XCTAssertTrue(hello[0].contains(#""state":"bypassed""#), hello[0])
        usleep(100_000)
        queue.sync { server.publish(.enabled(false)) }
        let lines = readLines(fd, count: 1, within: 0.3)
        XCTAssertEqual(lines.map(kind), ["enabled"], "\(lines)")
        XCTAssertEqual(queue.sync { frames }, 0, "no frame was ever computed")
        XCTAssertEqual(queue.sync { server.clients }, 0)
        XCTAssertEqual(observedChanges(), [], "metering never switched on")
    }

    func testMeterAndEventClientsEachGetOnlyTheirOwnLines() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let meter = try connect()
        defer { close(meter) }
        let events = try connect()
        send(events, "{\"subscribe\":\"events\"}\n")
        XCTAssertEqual(readLines(events, count: 1, within: 0.3).map(kind), ["daemon"])
        XCTAssertTrue(waitUntil(0.5) { queue.sync { server.clients } == 1 })
        queue.sync { server.publish(.solo(nil)) }
        XCTAssertEqual(readLines(events, count: 1, within: 0.3).map(kind), ["solo"])
        let frames = readLines(meter, count: 5, within: 0.5)
        XCTAssertGreaterThanOrEqual(frames.count, 5)
        XCTAssertTrue(frames.allSatisfy { kind($0) == nil && $0.contains("\"peak\"") }, "\(frames)")
        close(events)
        usleep(50_000)
        XCTAssertEqual(observedChanges(), [1], "an events client coming and going never touches the meter count")
    }

    func testEventClientsCountTowardsTheCap() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let kept = try (0..<MeterServer.maxClients).map { _ in try connect() }
        defer { kept.forEach { close($0) } }
        for fd in kept { send(fd, "{\"subscribe\":\"events\"}\n") }
        for fd in kept { XCTAssertEqual(readLines(fd, count: 1, within: 0.3).map(kind), ["daemon"]) }
        let extra = try connect()
        defer { close(extra) }
        var byte: UInt8 = 0
        var closed = false
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, !closed { closed = read(extra, &byte, 1) == 0 }
        XCTAssertTrue(closed, "the ninth client gets EOF")
    }

    func testSubscribeWithAnotherTopicIsMalformed() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let fd = try connect()
        defer { close(fd) }
        send(fd, "{\"subscribe\":\"volume\"}\n")
        let lines = readLines(fd, count: 2, within: 0.3)
        XCTAssertTrue(lines.count >= 2 && lines.allSatisfy { kind($0) == nil }, "still a meter client: \(lines)")
    }

    /// The peer is gone before its connection is accepted: SO_NOSIGPIPE then fails with EINVAL,
    /// so the hello write would raise SIGPIPE and kill the whole test process.
    func testAClientGoneBeforeItsAcceptDoesNotKillTheProcess() throws {
        let previous = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, previous) }
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        queue.suspend()
        let gone = try connect()
        send(gone, "{\"subscribe\":\"events\"}\n{\"solo\":{\"low\":300,\"high\":2800}}\n")
        close(gone)
        queue.resume()
        let next = try connect()
        defer { close(next) }
        send(next, "{\"subscribe\":\"events\"}\n")
        XCTAssertEqual(readLines(next, count: 1, within: 0.3).map(kind), ["daemon"])
        XCTAssertEqual(observedSolos(), [], "a request from a peer already gone is never acted on")
    }

    func testTheDaemonIgnoresSIGPIPE() {
        let previous = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, previous) }
        Daemon.ignoreBrokenPipes()
        XCTAssertEqual(signal(SIGPIPE, SIG_DFL).map { unsafeBitCast($0, to: Int.self) }, unsafeBitCast(SIG_IGN, to: Int.self))
    }

    /// A write that fails on the subscribe drops the client; a solo line read in the same chunk
    /// must not then take ownership for a descriptor nobody can speak for any more.
    func testLinesAfterADropInTheSameReadAreIgnored() throws {
        let server = makeServer()
        try server.start()
        defer { queue.sync { server.stop() } }
        let fd = try connect()
        XCTAssertTrue(waitUntil(0.5) { observedChanges() == [1] }, "accepted and decided: \(observedChanges())")
        queue.suspend()
        send(fd, "{\"subscribe\":\"events\"}\n{\"solo\":{\"low\":300,\"high\":2800}}\n")
        close(fd)
        queue.resume()
        usleep(100_000)
        let solos = observedSolos()
        XCTAssertTrue(solos.isEmpty || solos.last == .some(nil), "no solo left behind: \(solos)")
    }

    /// A one-tick decision belongs to a connection, not to its descriptor number, which the next
    /// accept may reuse while the old timer is still pending.
    func testAReusedDescriptorDoesNotInheritTheOldTickDecision() throws {
        let tick = 1.0
        let server = makeServer(tick: tick)
        try server.start()
        defer { queue.sync { server.stop() } }
        let first = try connect()
        usleep(50_000)
        close(first)
        usleep(150_000)
        let connected = Date()
        let second = try connect()
        defer { close(second) }
        while Date().timeIntervalSince(connected) < tick - 0.15 { usleep(10_000) }
        let early = queue.sync { server.clients }
        guard Date().timeIntervalSince(connected) < tick else { throw XCTSkip("too slow to observe the window") }
        XCTAssertEqual(early, 0, "the new connection must wait out its own tick")
        XCTAssertTrue(waitUntil(0.5) { queue.sync { server.clients } == 1 })
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
