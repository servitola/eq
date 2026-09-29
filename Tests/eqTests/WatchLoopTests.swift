import EQTerm
import XCTest
@testable import eq

final class WatchLoopTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private func frameLine(rate: Double = 44100, solo: SoloRange? = nil) throws -> String {
        let f = MeterFrame(t: 0, device: "BE-RCA", rate: rate, in: Array(repeating: -60, count: 10),
                           out: Array(repeating: -30, count: 10), peak: -6, limiting: false,
                           gains: Array(repeating: 0, count: 10), preamp: 0, enabled: true, solo: solo)
        return String(decoding: try MeterFrame.encodeLine(f).dropLast(), as: UTF8.self)
    }

    func testASoloRefusedWhileTheDeviceSettlesIsAskedAgain() throws {
        var keys: [String?] = ["]", "l", nil, nil, "]", nil]
        var sent: [String] = []
        let settling = try frameLine(rate: 0), settled = try frameLine()
        _ = MeterHarness.run(lines: [settling, settling, settling, settled, settled, settled, settled],
                             readKey: { keys.isEmpty ? nil : keys.removeFirst() }, send: { sent.append($0) })
        let kick = #"{"solo":{"low":50,"high":100}}"#, bass = #"{"solo":{"low":700,"high":1200}}"#
        XCTAssertEqual(sent, [kick, bass], "held back at 0 Hz, sent once the rate settles, then follows the focus")
    }

    private static let kick = #"{"solo":{"low":50,"high":100}}"#, bass = #"{"solo":{"low":700,"high":1200}}"#
    private static let kickSolo = SoloRange(low: 50, high: 100), bassSolo = SoloRange(low: 700, high: 1200)

    private func soloRun(_ frames: [String], keys: [String?]) -> (sent: [String], drawn: [String]) {
        var keys = keys
        var sent: [String] = []
        let run = MeterHarness.run(lines: frames, readKey: { keys.isEmpty ? nil : keys.removeFirst() }, send: { sent.append($0) })
        return (sent, run.drawn)
    }

    func testADeviceSwitchKeepsTheDaemonsSoloWithoutAskingAgain() throws {
        let r = soloRun([try frameLine(rate: 48000), try frameLine(rate: 48000, solo: Self.kickSolo),
                         try frameLine(rate: 0), try frameLine(rate: 44100, solo: Self.kickSolo)],
                        keys: ["]l"])
        XCTAssertEqual(r.sent, [Self.kick], "the daemon carries the solo across the rebuild")
        XCTAssertFalse(r.drawn.contains { $0.contains("can't listen") })
    }

    func testARefocusAtZeroHertzClearsTheOldSoloAndAsksOnceARateArrives() throws {
        let r = soloRun([try frameLine(), try frameLine(solo: Self.kickSolo), try frameLine(rate: 0),
                         try frameLine(), try frameLine()],
                        keys: ["]l", nil, "]"])
        XCTAssertEqual(r.sent, [Self.kick, #"{"solo":null}"#, Self.bass],
                       "kick must not keep sounding under the bass focus; bass goes out once, at 44.1 kHz")
        XCTAssertFalse(r.drawn.contains { $0.contains("can't listen") })
    }

    func testASoloDroppedBetweenFramesIsAskedForOnce() throws {
        // The refocus reached the daemon during a 0 Hz moment no frame showed, so it was refused.
        let r = soloRun([try frameLine(), try frameLine(solo: Self.kickSolo), try frameLine(), try frameLine(), try frameLine()],
                        keys: ["]l", "]"])
        XCTAssertEqual(r.sent, [Self.kick, Self.bass, Self.bass])
    }

    func testKeysBetweenFramesAreHandledAndRedrawn() throws {
        var keys: [String?] = [nil, "]", "q"]
        let line = try frameLine()
        let run = MeterHarness.run(lines: [line, "", "", ""], readKey: { keys.isEmpty ? nil : keys.removeFirst() })
        let drawn = run.drawn
        XCTAssertEqual(run.code, 0, "q quits with no frame after the first")
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
        XCTAssertEqual(actions(""), [.unfocus, .focusPrevious, .bandStep(0, 0.5), .palette],
                       "a terminal writes parameters and final byte together, so these were typed")
        XCTAssertEqual(actions("\u{1B}[1"), [])
        XCTAssertEqual(actions(""), [.unfocus, .focusPrevious, .bandStep(0, 0.5)])
        XCTAssertEqual(actions("2q"), [.bandStep(1, 0.5), .quit], "later digits and q are not held back")
        XCTAssertEqual(actions("\u{1B}[1;"), [])
        XCTAssertEqual(actions("5C"), [.knob(0.5)], "a sequence split across reads still completes")
    }

    func testAnEscInsideAPendingSequenceStartsANewKey() {
        let expected: [WatchAction] = [.unfocus, .focusPrevious, .knob(0.5)]
        XCTAssertEqual(WatchKeys.actions(for: "\u{1B}[\u{1B}[C"), expected)
        var buffer = KeyBuffer()
        func actions(_ bytes: String) -> [WatchAction] { WatchKeys.actions(for: buffer.feed(Array(bytes.utf8)) ?? "") }
        XCTAssertEqual(actions("\u{1B}[\u{1B}[C"), expected)
        XCTAssertEqual(actions("\u{1B}["), [])
        XCTAssertEqual(actions("\u{1B}[C"), expected, "split across reads too")
        XCTAssertEqual(actions("\u{1B}[1\u{1B}OD"), [.unfocus, .focusPrevious, .bandStep(0, 0.5), .knob(-0.5)])
        XCTAssertEqual(actions("\u{1B}[B\u{1B}[D"), [.cyclePreset, .knob(-0.5)], "whole arrows in one read are unchanged")
    }

    /// The real loop: keys are read while the daemon sends no frames, with no idle wake-up.
    func testKeysArriveWhileNoFramesDo() throws {
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
        let effects = MeterEffects(edit: { _ in }, header: { Watch.Header() }, send: client.send, mouse: { _ in }, connect: { nil })
        let runtime = Runtime(MeterModel(size: Size(cols: 80, rows: 24)), size: Size(cols: 80, rows: 24),
                              translate: MeterEffects.translate, perform: effects.perform, output: { _ in })
        runtime.inputFD = pipeFDs[0]
        runtime.watch(fd: try XCTUnwrap(client.descriptor), id: MeterEffects.meterSource, latestOnly: true)
        _ = write(pipeFDs[1], "]q", 2)
        let started = Date()
        XCTAssertEqual(runtime.run(), 0)
        XCTAssertEqual(runtime.program.focus, 0, "the key before q was handled too")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testTheDaemonGoingEndsTheWatchButTheTUIReconnects() {
        var watch = MeterModel(size: Size(cols: 80, rows: 24))
        XCTAssertEqual(watch.update(.meterClosed), [.quit(1)], "eq watch keeps its exit 1")
        var tui = MeterModel(size: Size(cols: 80, rows: 24), reconnects: true)
        _ = tui.update(.frame(MeterFrameTests.sample))
        XCTAssertEqual(tui.update(.meterClosed), [.retry(after: 0.5)])
        XCTAssertTrue(tui.lines()![22].hasSuffix(Watch.reconnecting), "said in the message row, over the last frame")
        XCTAssertEqual(tui.update(.retry), [.connect])
        XCTAssertEqual(tui.update(.connectFailed), [.retry(after: 1)])
        XCTAssertEqual(tui.update(.connectFailed), [.retry(after: 2)])
        XCTAssertEqual(tui.update(.connectFailed), [.retry(after: 4)])
        XCTAssertEqual(tui.update(.connectFailed), [.retry(after: 4)], "capped at 4 s")
        XCTAssertEqual(tui.update(.connected), [])
        XCTAssertFalse(tui.lines()![22].contains(Watch.reconnecting))
    }

    func testAListenGoesOutAgainAfterAReconnect() {
        var tui = MeterModel(size: Size(cols: 80, rows: 24), reconnects: true)
        _ = tui.update(.frame(MeterFrameTests.sample))
        _ = tui.update(.input(.key(KeyPress(.char("]")))))
        XCTAssertEqual(tui.update(.input(.key(KeyPress(.char("l"))))).count, 1)
        _ = tui.update(.meterClosed)
        _ = tui.update(.connected)
        var frame = MeterFrameTests.sample
        frame.solo = nil
        XCTAssertEqual(tui.update(.frame(frame)).filter { if case .send = $0 { return true } else { return false } }.count, 1,
                       "the daemon dropped the solo with the socket; the next frame asks again")
    }
}
