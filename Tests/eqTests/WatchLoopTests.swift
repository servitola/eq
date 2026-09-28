import XCTest
@testable import eq

final class WatchLoopTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private struct Source: MeterSource {
        let lines: [String]
        func lines(maxLines: Int?, handle: (String) -> Bool) -> Bool {
            for line in lines { guard handle(line) else { return false } }
            return true
        }
    }

    private func frameLine(rate: Double = 44100) throws -> String {
        let f = MeterFrame(t: 0, device: "BE-RCA", rate: rate, in: Array(repeating: -60, count: 10),
                           out: Array(repeating: -30, count: 10), peak: -6, limiting: false,
                           gains: Array(repeating: 0, count: 10), preamp: 0, enabled: true)
        return String(decoding: try MeterFrame.encodeLine(f).dropLast(), as: UTF8.self)
    }

    func testASoloRefusedWhileTheDeviceSettlesIsAskedAgain() throws {
        var keys: [String?] = ["]", "l", nil, nil, "]", nil]
        var sent: [String] = []
        let settling = try frameLine(rate: 0), settled = try frameLine()
        _ = Watch.run(source: Source(lines: [settling, settling, settling, settled, settled, settled, settled]), hintDismissed: true,
                      emit: { _ in }, readKey: { keys.isEmpty ? nil : keys.removeFirst() }, send: { sent.append($0) })
        let kick = #"{"solo":{"low":50,"high":100}}"#, bass = #"{"solo":{"low":700,"high":1200}}"#
        XCTAssertEqual(sent, [kick, kick, bass], "sent at 0 Hz, again once the rate settles, then follows the focus")
    }

    func testKeysBetweenFramesAreHandledAndRedrawn() throws {
        var keys: [String?] = [nil, "]", "q"]
        var drawn: [String] = []
        let line = try frameLine()
        let code = Watch.run(source: Source(lines: [line, "", "", ""]), hintDismissed: true,
                             emit: { if $0.contains("\u{1B}[H") { drawn.append($0) } },
                             readKey: { keys.isEmpty ? nil : keys.removeFirst() })
        XCTAssertEqual(code, 0, "q quits with no frame after the first")
        XCTAssertEqual(drawn.count, 2, "one frame, one redraw for the focus key")
        XCTAssertTrue(drawn[1].contains("focus: kick"), drawn[1])
    }

    func testEscThenBracketInOneReadIsNotASequence() {
        var buffer = KeyBuffer()
        func actions(_ bytes: String) -> [WatchAction] { WatchKeys.actions(for: buffer.feed(Array(bytes.utf8)) ?? "") }
        XCTAssertEqual(actions("\u{1B}["), [])
        XCTAssertEqual(actions(""), [.unfocus, .focusPrevious])
        XCTAssertEqual(actions("q"), [.quit], "the next key is not swallowed as a final byte")
        XCTAssertEqual(actions("\u{1B}O"), [])
        XCTAssertEqual(actions(""), [.unfocus])
        XCTAssertEqual(actions("\u{1B}[1;"), [])
        XCTAssertEqual(actions(""), [], "a sequence with parameters waits for its final byte")
        XCTAssertEqual(actions("C"), [.knob(0.5)])
    }

    func testTheClientWakesForInputWhileNoFramesArrive() throws {
        let socketDir = URL(fileURLWithPath: "/tmp/eq-loop-\(getpid())-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: socketDir) }
        let queue = DispatchQueue(label: "loop-test")
        let server = MeterServer(socketURL: socketDir.appendingPathComponent("m.sock"), queue: queue, tick: 3600,
                                 source: { MeterFrameTests.sample }, onClientsChanged: { _ in })
        try server.start()
        defer { queue.sync { server.stop() } }
        var pipeFDs: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFDs), 0)
        defer { close(pipeFDs[0]); close(pipeFDs[1]) }
        let client = MeterClient(socketURL: socketDir.appendingPathComponent("m.sock"))
        try client.connect()
        defer { client.close() }
        client.input = pipeFDs[0]
        _ = write(pipeFDs[1], "q", 1)
        let started = Date()
        var woken: [String] = []
        let eof = client.lines { line in
            woken.append(line)
            var byte: UInt8 = 0
            return read(pipeFDs[0], &byte, 1) != 1
        }
        XCTAssertFalse(eof)
        XCTAssertEqual(woken, [""])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
