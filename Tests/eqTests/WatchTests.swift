import XCTest
@testable import eq

final class WatchTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private func frame(out: Double = -6, in input: Double = -60, gains: [Double] = Array(repeating: 0, count: 10),
                       limiting: Bool = false, enabled: Bool = true) -> MeterFrame {
        MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: Array(repeating: input, count: 10),
                   out: Array(repeating: out, count: 10), peak: -6, limiting: limiting,
                   gains: gains, preamp: -1.5, enabled: enabled)
    }

    private func context(tty: Bool, cols: Int = 80, rows: Int = 24) -> CLIContext {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-watch-\(UUID().uuidString)")
        var ctx = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [] },
            defaultOutput: { nil },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-27" })
        ctx.meterSocketURL = dir.appendingPathComponent("meter.sock")
        ctx.terminal = { (tty, cols, rows) }
        return ctx
    }

    func testFrameShape() {
        var gains = Array(repeating: 0.0, count: 10)
        gains[0] = 12
        gains[1] = -12
        let lines = Watch.frame(frame(gains: gains))
        XCTAssertEqual(lines.count, 1 + Watch.meterRows + 2)
        XCTAssertEqual(lines[0], "BE-RCA · 44.1 kHz · preamp -1.5 dB")
        XCTAssertEqual(lines[13], Table.labelsRow())
        XCTAssertEqual(lines[14], Table.gainsRow(gains))

        let meter = Array(lines[1...12])
        func cell(_ row: Int, _ column: Int) -> Character {
            Array(meter[row])[column * 6 + 5]
        }
        XCTAssertTrue(meter.allSatisfy { $0.count == 60 }, "\(meter)")
        XCTAssertEqual(cell(0, 0), "▬")
        XCTAssertEqual(cell(11, 1), "▬")
        XCTAssertEqual(cell(0, 2), " ")
        XCTAssertEqual(cell(1, 2), " ")
        for row in 2...11 where row != 6 { XCTAssertEqual(cell(row, 2), "█", "row \(row)") }
        XCTAssertEqual(cell(6, 2), "▬")
        XCTAssertFalse(meter.joined().contains("░"))
    }

    func testFrameShowsInputAboveOutputAndHeaderFlags() {
        let lines = Watch.frame(frame(out: -40, in: 0, limiting: true, enabled: false))
        XCTAssertEqual(Array(lines[1])[5], "░")
        XCTAssertEqual(Array(lines[12 - 1])[5], "█")
        XCTAssertTrue(lines[0].hasPrefix("BE-RCA · 44.1 kHz · preamp -1.5 dB BYPASS"), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("LIMIT"), lines[0])
        XCTAssertEqual(lines[0].count, 60)
    }

    func testFrameNoEscapesWhenPlain() {
        let text = Watch.frame(frame(gains: Config.screenshotCurve, limiting: true)).joined()
        XCTAssertFalse(text.contains("\u{1B}"))
    }

    func testFramePaintsBoost() {
        Paint.forced = true
        let text = Watch.frame(frame(gains: Array(repeating: 4.8, count: 10), limiting: true)).joined()
        XCTAssertTrue(text.contains("\u{1B}[32m█"), text)
        XCTAssertTrue(text.contains("\u{1B}[33mLIMIT"), text)
    }

    func testWatchRefusesNonTTY() {
        for ctx in [context(tty: false), context(tty: true, cols: 63, rows: 24), context(tty: true, cols: 80, rows: 15)] {
            let result = CLI.run(["watch"], context: ctx)
            XCTAssertEqual(result.exitCode, 2)
            XCTAssertTrue(result.output.contains("eq watch needs a terminal of at least 64×16"), result.output)
        }
        let result = CLI.run(["watch"], context: context(tty: true))
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("not serving"), result.output)
    }

    func testWatchHasNoJSON() {
        let result = CLI.run(["watch", "--json"], context: context(tty: true))
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("eq watch has no JSON form; use eq stream"), result.output)
    }

    func testFrameToleratesHugeGain() {
        var gains = Array(repeating: 0.0, count: 10)
        gains[3] = 1e308
        gains[7] = -Double.infinity
        gains[9] = Double.nan
        let lines = Watch.frame(frame(gains: gains))
        XCTAssertEqual(lines.count, 1 + Watch.meterRows + 2)
        func cell(_ row: Int, _ column: Int) -> Character {
            Array(lines[1 + row])[column * 6 + 5]
        }
        XCTAssertEqual(cell(0, 3), "▬")
    }

    func testFrameToleratesShortArrays() {
        let short = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: [-20], out: [],
                                peak: -6, limiting: false, gains: [3], preamp: -1.5, enabled: true)
        let lines = Watch.frame(short)
        XCTAssertEqual(lines.count, 1 + Watch.meterRows + 2)
        let expectedGains = [3.0] + Array(repeating: 0.0, count: 9)
        XCTAssertEqual(lines.last!, Table.gainsRow(expectedGains))
    }

    func testRunLoopExitsOnQ() throws {
        struct Source: MeterSource {
            let lines: [String]
            func lines(maxLines: Int?, handle: (String) -> Bool) -> Bool {
                for line in lines { guard handle(line) else { return false } }
                return true
            }
        }
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        var emitted: [String] = []
        var frames = 0
        let code = Watch.run(source: Source(lines: Array(repeating: line, count: 5)),
                             emit: { emitted.append($0); if $0.hasPrefix("\u{1B}[H") { frames += 1 } },
                             readKey: { frames >= 2 ? UInt8(ascii: "q") : nil })
        XCTAssertEqual(code, 0)
        XCTAssertEqual(frames, 2)
        XCTAssertEqual(emitted.first, Watch.enter)
        XCTAssertEqual(emitted.last, Watch.leave)
    }

    func testRunLoopExitsOneOnEOF() throws {
        struct Source: MeterSource {
            let lines: [String]
            func lines(maxLines: Int?, handle: (String) -> Bool) -> Bool {
                for line in lines { guard handle(line) else { return false } }
                return true
            }
        }
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        var emitted: [String] = []
        let code = Watch.run(source: Source(lines: [line, line]),
                             emit: { emitted.append($0) },
                             readKey: { nil })
        XCTAssertEqual(code, 1)
        XCTAssertEqual(emitted.first, Watch.enter)
        XCTAssertEqual(emitted.last, Watch.leave)
    }
}
