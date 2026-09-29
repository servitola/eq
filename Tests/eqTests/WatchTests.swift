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

    private let wide = WatchLayout(columns: 10, cellWidth: 6, meterRows: 12, shortLabels: false, width: 60)

    private func cell(_ line: String, _ column: Int, width: Int = 6) -> Character {
        Array(line)[column * width + width - 1]
    }

    func testFitCases() {
        XCTAssertEqual(WatchLayout.fit(cols: 200, rows: 50), WatchLayout(columns: 10, cellWidth: 8, meterRows: 44, shortLabels: false, width: 200))
        XCTAssertEqual(WatchLayout.fit(cols: 64, rows: 16), WatchLayout(columns: 10, cellWidth: 6, meterRows: 10, shortLabels: false, width: 64))
        XCTAssertEqual(WatchLayout.fit(cols: 40, rows: 12), WatchLayout(columns: 9, cellWidth: 4, meterRows: 6, shortLabels: true, width: 40))
        XCTAssertEqual(WatchLayout.fit(cols: 24, rows: 10), WatchLayout(columns: 5, cellWidth: 4, meterRows: 4, shortLabels: true, width: 24))
        XCTAssertEqual(WatchLayout.fit(cols: 24, rows: 9),
                       WatchLayout(columns: 5, cellWidth: 4, meterRows: 4, shortLabels: true, width: 24, folded: true),
                       "below ten rows the message row folds into the keybar and the meter keeps four rows")
        XCTAssertEqual(WatchLayout.fit(cols: 24, rows: 7).meterRows, 2)
        XCTAssertEqual(WatchLayout.fit(cols: 42, rows: 5).columns, 10)
        XCTAssertEqual(WatchLayout.fit(cols: 41, rows: 5).columns, 9)
        XCTAssertEqual(WatchLayout.fit(cols: 0, rows: 0), WatchLayout(columns: 1, cellWidth: 4, meterRows: 1, shortLabels: true, width: 0, folded: true))
    }

    func testFrameShape() {
        var gains = Array(repeating: 0.0, count: 10)
        gains[0] = 12
        gains[1] = -12
        let lines = Watch.frame(frame(gains: gains), layout: wide)
        XCTAssertEqual(lines.count, 1 + 12 + 1 + 2 + 2)
        XCTAssertEqual(lines[0], "BE-RCA · 44.1 kHz · preamp -1.5 dB · peak -6.0 dB")
        XCTAssertEqual(lines[16], "", "the message row is kept even when empty, so a note never moves the meter")
        XCTAssertEqual(lines[17], "1…0 band  ⇧ down  z zones off  i instruments  ? keys  q quit")
        XCTAssertEqual(lines[14], Table.labelsRow())
        XCTAssertEqual(lines[15], Table.gainsRow(gains))

        let meter = Array(lines[1...12])
        XCTAssertTrue(meter.allSatisfy { $0.count == 60 }, "\(meter)")
        XCTAssertEqual(cell(meter[0], 0), "▬")
        XCTAssertEqual(cell(meter[11], 1), "▬")
        XCTAssertEqual(cell(meter[0], 2), " ")
        // out -6 at 12 rows reaches 10.8 rows: ten full cells and a 0.8 partial above them.
        XCTAssertEqual(cell(meter[1], 2), "▇")
        // A six-column cell draws a two-glyph bar, right-aligned under a space.
        XCTAssertEqual(Array(meter[1])[12..<18].map(String.init).joined(), "    ▇▇")
        XCTAssertEqual(Array(meter[0])[0..<6].map(String.init).joined(), "    ▬▬")
        for row in 2...11 where row != 6 { XCTAssertEqual(cell(meter[row], 2), "█", "row \(row)") }
        XCTAssertEqual(cell(meter[6], 2), "▬")
        XCTAssertFalse(meter.joined().contains("░"))
        XCTAssertEqual(lines[13], String(repeating: "    -6", count: 10))
    }

    func testFrameRowCounts() {
        for (cols, rows) in [(200, 50), (64, 16), (40, 12), (24, 10), (10, 3)] {
            let layout = WatchLayout.fit(cols: cols, rows: rows)
            let lines = Watch.frame(frame(), layout: layout)
            XCTAssertEqual(lines.count, 1 + layout.meterRows + 3 + (layout.folded ? 1 : 2), "\(cols)×\(rows)")
            if rows >= 6 { XCTAssertEqual(lines.count, rows, "\(cols)×\(rows)") }
            for line in lines.dropFirst() {
                XCTAssertLessThanOrEqual(line.count, max(cols, layout.columns * layout.cellWidth), "\(cols)×\(rows): \(line)")
            }
            XCTAssertLessThanOrEqual(lines[0].count, cols, "\(cols)×\(rows): \(lines[0])")
        }
    }

    func testNarrowShowsLowestBandsAndNote() {
        let layout = WatchLayout.fit(cols: 24, rows: 10)
        let lines = Watch.frame(frame(gains: Config.screenshotCurve), layout: layout)
        XCTAssertEqual(lines[lines.count - 4], "    32  64 125 250 500")
        XCTAssertEqual(lines[lines.count - 3], "    +5  +4  +4  +2   0")
        XCTAssertEqual(lines[lines.count - 2], "  … widen for all bands")
        XCTAssertEqual(lines.last, "1…0 band  ? keys  q quit")
        XCTAssertEqual(lines[1 + layout.meterRows].count, 22)
    }

    func testFractionalTop() {
        let flat = WatchLayout(columns: 10, cellWidth: 6, meterRows: 12, shortLabels: false, width: 60)
        var gains = Array(repeating: -12.0, count: 10)
        gains[0] = -12
        let exact = Array(Watch.frame(frame(out: -30, gains: gains), layout: flat)[1...12])
        for row in 6...10 { XCTAssertEqual(cell(exact[row], 0), "█", "row \(row)") }
        XCTAssertEqual(cell(exact[5], 0), " ")
        let partial = Array(Watch.frame(frame(out: -27, gains: gains), layout: flat)[1...12])
        for row in 6...10 { XCTAssertEqual(cell(partial[row], 0), "█", "row \(row)") }
        XCTAssertEqual(cell(partial[5], 0), "▅")
        XCTAssertEqual(cell(partial[4], 0), " ")
        let floor = Array(Watch.frame(frame(out: -60), layout: flat)[1...12])
        XCTAssertEqual(cell(floor[11], 3), " ")
    }

    func testLiveRow() {
        XCTAssertEqual(Watch.frame(frame(out: -27), layout: wide)[13], String(repeating: "   -27", count: 10))
        XCTAssertEqual(Watch.frame(frame(out: -60), layout: wide)[13], String(repeating: "     ·", count: 10))
        XCTAssertEqual(Watch.frame(frame(out: -0.3), layout: wide)[13], String(repeating: "     0", count: 10))
        let short = WatchLayout.fit(cols: 40, rows: 12)
        XCTAssertEqual(Watch.frame(frame(out: -27), layout: short)[1 + short.meterRows], "  " + String(repeating: " -27", count: 9))
    }

    func testHotShades() {
        Paint.forced = true
        let boost = Array(repeating: 4.8, count: 10)
        let hot = Watch.frame(frame(out: -3, gains: boost), layout: wide).joined()
        XCTAssertTrue(hot.contains("\u{1B}[92m█"), hot)
        XCTAssertTrue(hot.contains("\u{1B}[92m    -3"), hot)
        XCTAssertFalse(hot.contains("\u{1B}[32m█"), hot)
        let cool = Watch.frame(frame(out: -20, gains: boost), layout: wide).joined()
        XCTAssertTrue(cool.contains("\u{1B}[32m█"), cool)
        XCTAssertFalse(cool.contains("\u{1B}[92m█"), cool)
        let big = Watch.frame(frame(out: -20, gains: Array(repeating: -9, count: 10)), layout: wide).joined()
        XCTAssertTrue(big.contains("\u{1B}[95m▬"), big)
        // A flat band never gets a colour, but when hot its bar must not stay dim.
        let flatHot = Watch.frame(frame(out: -3), layout: wide)
        XCTAssertTrue(flatHot[5].contains("    ██"), flatHot[5])
        XCTAssertFalse(flatHot[5].contains("\u{1B}[2m█"), flatHot[5])
        let flatCool = Watch.frame(frame(out: -20), layout: wide).joined()
        XCTAssertTrue(flatCool.contains("\u{1B}[2m█"), flatCool)
    }

    func testHeaderTruncation() {
        let narrow = Watch.frame(frame(), layout: WatchLayout.fit(cols: 40, rows: 12))
        XCTAssertEqual(narrow[0], "  BE-RCA · 44.1 kHz · preamp -1.5 dB")
        let flagged = Watch.frame(frame(limiting: true, enabled: false), layout: WatchLayout.fit(cols: 40, rows: 12))
        XCTAssertEqual(flagged[0], "  BE-RCA · 44.1 kHz BYPASS       LIMIT")
        XCTAssertEqual(flagged[0].count, flagged[1].count, "LIMIT ends where the bars do")
        let tiny = Watch.frame(frame(), layout: WatchLayout.fit(cols: 4, rows: 12))
        XCTAssertLessThanOrEqual(tiny[0].count, 4, tiny[0])
    }

    func testFrameShowsInputAboveOutputAndHeaderFlags() {
        let layout = WatchLayout(columns: 10, cellWidth: 6, meterRows: 12, shortLabels: false, width: 64)
        let lines = Watch.frame(frame(out: -40, in: 0, limiting: true, enabled: false), layout: layout)
        XCTAssertEqual(cell(String(lines[1].dropFirst(2)), 0), "░")
        XCTAssertEqual(cell(String(lines[12].dropFirst(2)), 0), "█")
        XCTAssertTrue(lines[0].hasPrefix("  BE-RCA · 44.1 kHz · preamp -1.5 dB · peak -6.0 dB BYPASS"), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("LIMIT"), lines[0])
        XCTAssertEqual(lines[0].count, 64)
    }

    func testFrameCentresInWideTerminal() {
        let layout = WatchLayout.fit(cols: 100, rows: 30)
        let lines = Watch.frame(frame(), layout: layout)
        XCTAssertTrue(lines[0].hasPrefix(String(repeating: " ", count: 10) + "BE-RCA"), lines[0])
        for line in lines.dropFirst().dropLast(2) {
            XCTAssertTrue(line.hasPrefix(String(repeating: " ", count: 10)), line)
            XCTAssertEqual(line.count, 90, line)
        }
        XCTAssertEqual(lines[lines.count - 3], String(repeating: " ", count: 10) + Table.gainsRow(Array(repeating: 0, count: 10), width: 8))
    }

    func testCellWidthSetsBarWidth() {
        for (cellWidth, glyphs) in [(4, 1), (5, 2), (6, 2), (7, 3), (8, 3)] {
            let layout = WatchLayout(columns: 10, cellWidth: cellWidth, meterRows: 12, shortLabels: cellWidth < 6, width: cellWidth * 10)
            let bottom = Watch.frame(frame(), layout: layout)[12]
            let firstCell = String(Array(bottom)[0..<cellWidth])
            XCTAssertEqual(firstCell, String(repeating: " ", count: cellWidth - glyphs) + String(repeating: "█", count: glyphs), "\(cellWidth)")
        }
    }

    func testMarkerWinsOverPartialTop() {
        // out -27 at 12 rows tops out at 6.6 rows: the partial sits on row index 5, where gain +1 puts the marker.
        let lines = Watch.frame(frame(out: -27, gains: Array(repeating: 1, count: 10)), layout: wide)
        XCTAssertEqual(cell(lines[1 + 5], 0), "▬")
    }

    func testFrameNoEscapesWhenPlain() {
        let text = Watch.frame(frame(gains: Config.screenshotCurve, limiting: true), layout: wide).joined()
        XCTAssertFalse(text.contains("\u{1B}"))
    }

    func testFramePaintsBoost() {
        Paint.forced = true
        let text = Watch.frame(frame(out: -20, gains: Array(repeating: 4.8, count: 10), limiting: true), layout: wide).joined()
        XCTAssertTrue(text.contains("\u{1B}[32m█"), text)
        XCTAssertTrue(text.contains("\u{1B}[33mLIMIT"), text)
    }

    func testWatchRefusesNonTTYOnly() {
        let result = CLI.run(["watch"], context: context(tty: false))
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("eq watch needs a terminal"), result.output)
        for ctx in [context(tty: true), context(tty: true, cols: 20, rows: 6)] {
            let result = CLI.run(["watch"], context: ctx)
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertTrue(result.output.contains("daemon is not running"), result.output)
        }
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
        let lines = Watch.frame(frame(gains: gains), layout: wide)
        XCTAssertEqual(lines.count, 1 + 12 + 3 + 2)
        XCTAssertEqual(cell(lines[1], 3), "▬")
    }

    func testFrameToleratesShortArrays() {
        let short = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: [-20], out: [],
                                peak: -6, limiting: false, gains: [3], preamp: -1.5, enabled: true)
        let lines = Watch.frame(short, layout: wide)
        XCTAssertEqual(lines.count, 1 + 12 + 3 + 2)
        let expectedGains = [3.0] + Array(repeating: 0.0, count: 9)
        XCTAssertEqual(lines[lines.count - 3], Table.gainsRow(expectedGains))
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
                             readKey: { frames >= 2 ? "q" : nil })
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

    func testRunClearsOnceAfterResize() throws {
        struct Source: MeterSource {
            let lines: [String]
            func lines(maxLines: Int?, handle: (String) -> Bool) -> Bool {
                for line in lines { guard handle(line) else { return false } }
                return true
            }
        }
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        var emitted: [String] = []
        var calls = 0
        _ = Watch.run(source: Source(lines: Array(repeating: line, count: 5)),
                      size: { calls += 1; return calls <= 3 ? (80, 24) : (100, 30) },
                      emit: { emitted.append($0) }, readKey: { nil })
        let frames = emitted.filter { $0.contains("\u{1B}[H") }
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(frames.map { $0.components(separatedBy: "\u{1B}[2J").count - 1 }, [0, 0, 1, 0, 0])
        XCTAssertTrue(frames[2].contains("BE-RCA"))
        XCTAssertTrue(frames[4].contains(String(repeating: " ", count: 10) + "BE-RCA"), "the new layout is centred for 100 columns")
    }

    func testRunRendersTinyTerminal() throws {
        struct Source: MeterSource {
            let lines: [String]
            func lines(maxLines: Int?, handle: (String) -> Bool) -> Bool {
                for line in lines { guard handle(line) else { return false } }
                return true
            }
        }
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        var emitted: [String] = []
        let code = Watch.run(source: Source(lines: [line]), size: { (24, 10) },
                             emit: { emitted.append($0) }, readKey: { nil })
        XCTAssertEqual(code, 1)
        let drawn = try XCTUnwrap(emitted.first { $0.contains("\u{1B}[H") })
        XCTAssertTrue(drawn.contains("… widen for all bands"), drawn)
    }
}
