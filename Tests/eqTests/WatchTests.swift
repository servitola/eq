import EQTerm
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

    private func scene(_ f: MeterFrame, cols: Int = 100, rows: Int = 30, depth: ColorDepth = .none) -> MeterScene {
        MeterScreens.scene(f, cols: cols, rows: rows, depth: depth)
    }

    private func geometry(cols: Int = 100, rows: Int = 30) -> MeterGeometry {
        StudioView(scene: scene(frame(), cols: cols, rows: rows), compact: cols < 60 || rows < 12).geometry
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

    func testStudioGeometry() {
        let g = geometry(cols: 120, rows: 40)
        XCTAssertEqual(g.box, Rect(x: 0, y: 2, width: 93, height: 33), "under the tab row: the panel, then the 27-column side column")
        XCTAssertEqual(g.side, Rect(x: 93, y: 2, width: 27, height: 36))
        XCTAssertEqual([g.cell, g.barWidth, g.x0, g.top, g.rows, g.liveY], [8, 5, 7, 3, 31, 35])
        XCTAssertEqual(geometry(cols: 120, rows: 13).box?.y, 1, "below 14 rows there is no tab row")
        XCTAssertNil(geometry(cols: 109, rows: 40).side, "below 110 columns there is no side column")
        let centred = geometry(cols: 100, rows: 30)
        XCTAssertEqual(centred.box?.x, 3, "the panel is centred")
        XCTAssertFalse(geometry(cols: 59, rows: 30).boxed, "below 60 columns the compact rows")
        XCTAssertFalse(geometry(cols: 100, rows: 11).boxed, "and below 12 rows")
        for (cell, width, cols) in [(4, 3, 60), (6, 3, 73), (7, 5, 83), (8, 5, 93)] {
            XCTAssertEqual(geometry(cols: cols, rows: 30).cell, cell)
            XCTAssertEqual(geometry(cols: cols, rows: 30).barWidth, width, "\(cell)")
        }
    }

    func testFrameShape() {
        var gains = Array(repeating: 0.0, count: 10)
        gains[0] = 12
        gains[1] = -12
        let g = geometry()
        let lines = MeterScreens.lines(frame(gains: gains), cols: 100, rows: 30)
        XCTAssertEqual(lines.count, 30)
        XCTAssertTrue(lines[0].hasPrefix(" ◉ BE-RCA  44.1 kHz │ preamp -1.5 dB"), lines[0])
        XCTAssertTrue(lines[0].hasSuffix(" peak -6.0 dB "), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("  Meter   Instruments   Events "), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("   ╭─ meter ─"), lines[2])
        XCTAssertTrue(lines[2].contains(" dBFS · gain dB ╮"), lines[2])
        XCTAssertEqual(lines[g.liveY + 1].split(separator: " "), Config.bandLabels.map { Substring($0) })
        XCTAssertEqual(lines[g.liveY + 2].split(separator: " "), ["+12.0", "-12.0"] + Array(repeating: "0.0", count: 8))
        XCTAssertEqual(lines[28].trimmingCharacters(in: .whitespaces), "", "the message row is kept even when empty")
        XCTAssertTrue(lines[29].hasPrefix(" 1…0  band   ⇧  down   z  zones off"), lines[29])
        XCTAssertTrue(lines[g.top].contains("  0 ┤") && lines[g.top].contains("├+12"), "the dBFS and gain scales: \(lines[g.top])")
        XCTAssertTrue(lines[g.top + g.rows - 1].contains("-60 ┤") && lines[g.top + g.rows - 1].contains("├-12"))
    }

    func testFrameRowCounts() {
        for (cols, rows) in [(200, 50), (64, 16), (40, 12), (24, 10), (10, 3), (120, 40), (59, 11)] {
            XCTAssertEqual(MeterScreens.lines(frame(), cols: cols, rows: rows).count, rows, "\(cols)×\(rows)")
        }
    }

    func testNarrowShowsLowestBandsAndNote() {
        let lines = MeterScreens.lines(frame(gains: Config.screenshotCurve), cols: 24, rows: 10).map {
            $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        XCTAssertEqual(lines[lines.count - 4], "    32  64 125 250 500")
        XCTAssertEqual(lines[lines.count - 3], "    +5  +4  +4  +2   0")
        XCTAssertEqual(lines[lines.count - 2], "  … widen for all bands")
        XCTAssertEqual(lines.last, " ?  keys   q  quit")
    }

    /// Solid cells are spaces painted by row: green below −18 dBFS, amber to −6, red above,
    /// whatever the band's gain.
    func testBarsAreColouredByHeight() {
        let s = scene(frame(out: -1, gains: Array(repeating: 4.8, count: 10)), depth: .ansi)
        let g = StudioView(scene: s, compact: false).geometry
        let screen = MeterScreens.screen(s)
        let x = g.barX(0)
        for b in 0..<g.rows {
            let cell = screen[x, g.top + g.rows - 1 - b]
            let db = -60 + (Double(b) + 0.5) / Double(g.rows) * 60
            let zone: UInt8 = db < -18 ? 2 : (db < -6 ? 3 : 1)
            guard cell.text == " " else { continue }
            XCTAssertEqual(cell.style.bg, .ansi(zone), "row \(b) at \(db) dBFS")
        }
        XCTAssertEqual(screen[x, g.top + g.rows - 1].style.bg, .ansi(2))
        XCTAssertEqual(screen[x, g.top + 1].style.bg, .ansi(1))
    }

    func testFractionalTopAndPeakTick() {
        var s = scene(frame(out: -26))
        s.settings.curve = false
        s.peaks = Array(repeating: -9, count: 10)
        let g = StudioView(scene: s, compact: false).geometry
        let screen = MeterScreens.screen(s)
        let column = (0..<g.rows).map { screen[g.barX(3), g.top + $0].text }
        let height = 34.0 / 60 * Double(g.rows)
        XCTAssertEqual(column.last, " ")
        XCTAssertEqual(column[g.rows - 1 - Int(height)], Watch.partials[Int((height - Double(Int(height))) * 8)])
        let tick = g.rows - 1 - Int(51.0 / 60 * Double(g.rows))
        XCTAssertEqual(column[tick], "▔", "the held peak at -9 dBFS: \(column)")
        s.peaks = nil
        XCTAssertFalse(MeterScreens.screen(s).lines().joined().contains("▔"), "--no-peaks")
    }

    func testLiveRow() {
        let g = geometry()
        XCTAssertEqual(MeterScreens.lines(frame(out: -27), cols: 100, rows: 30)[g.liveY].split(separator: " "),
                       Array(repeating: "-27", count: 10))
        XCTAssertEqual(MeterScreens.lines(frame(out: -60), cols: 100, rows: 30)[g.liveY].split(separator: " "),
                       Array(repeating: "·", count: 10))
        XCTAssertEqual(MeterScreens.lines(frame(out: -0.3), cols: 100, rows: 30)[g.liveY].split(separator: " "),
                       Array(repeating: "0", count: 10))
    }

    func testHeaderDropsSegmentsToFit() {
        let narrow = MeterScreens.lines(frame(), cols: 44, rows: 12)[0]
        XCTAssertEqual(narrow, " ◉ BE-RCA  44.1 kHz            peak -6.0 dB ")
        let flagged = MeterScreens.lines(frame(limiting: true, enabled: false), cols: 44, rows: 12)[0]
        XCTAssertEqual(flagged, " ◉ BE-RCA     peak -6.0 dB  BYPASS   LIMIT  ", "the flags explain a surprising sound, so they stay")
        let tiny = MeterScreens.lines(frame(), cols: 4, rows: 12)[0]
        XCTAssertEqual(tiny, " ◉ B")
    }

    func testInputAboveOutputAndHeaderFlags() {
        var s = scene(frame(out: -40, in: 0, limiting: true, enabled: false))
        s.settings.curve = false
        let g = StudioView(scene: s, compact: false).geometry
        let lines = MeterScreens.screen(s).lines()
        XCTAssertEqual(Array(lines[g.top])[g.barX(0)], "░", "the input reaches the top")
        XCTAssertEqual(Array(lines[g.top + g.rows - 1])[g.barX(0)], " ")
        XCTAssertTrue(lines[0].hasSuffix(" BYPASS   LIMIT  "), lines[0])
    }

    func testCurveFollowsTheGainsAndTintsBoostAndCut() {
        let flat = MeterScreens.screen(scene(frame(out: -60)))
        let g = geometry()
        let zero = g.top + Int((Double(g.rows * 4 - 1) / 2).rounded()) / 4
        let braille = #"[\u{2801}-\u{28FF}]{4}"#
        XCTAssertNotNil(flat.lines()[zero].range(of: braille, options: .regularExpression), "a flat curve lies on the 0 dB line: \(flat.lines()[zero])")
        XCTAssertEqual(flat.lines().filter { $0.range(of: braille, options: .regularExpression) != nil }.count, 1, "and nowhere else")
        var gains = Array(repeating: 0.0, count: 10)
        gains[2] = 12
        gains[7] = -12
        let s = scene(frame(out: -60, gains: gains), depth: .truecolor)
        let screen = MeterScreens.screen(s)
        let top = (g.top..<(g.top + g.rows)).first { y in (screen[g.centre(2), y].text.unicodeScalars.first?.value ?? 0) >= 0x2800 }!
        let bottom = (g.top..<(g.top + g.rows)).last { y in (screen[g.centre(7), y].text.unicodeScalars.first?.value ?? 0) >= 0x2800 }!
        XCTAssertLessThanOrEqual(top, g.top + 1, "+12 dB at 125 Hz reaches the top")
        XCTAssertGreaterThanOrEqual(bottom, g.top + g.rows - 2, "-12 dB at 4 kHz the bottom")
        let fill = Theme(palette: .ink, depth: .truecolor).p
        XCTAssertEqual(screen[g.centre(2), zero - 2].style.bg, .rgb(fill.boostFill.r, fill.boostFill.g, fill.boostFill.b))
        XCTAssertEqual(screen[g.centre(7), zero + 2].style.bg, .rgb(fill.cutFill.r, fill.cutFill.g, fill.cutFill.b))
        XCTAssertEqual(Curve.response(gains, at: 125, rate: 44100), 12, accuracy: 0.2)
        XCTAssertEqual(Curve.response(gains, at: 4000, rate: 44100), -12, accuracy: 0.2)
    }

    func testMonochromeKeepsTheLookInReverseVideo() {
        let s = scene(frame(out: -3, limiting: true), depth: .none)
        let screen = MeterScreens.screen(s)
        let g = StudioView(scene: s, compact: false).geometry
        XCTAssertEqual(screen[g.barX(0), g.top + g.rows - 1].style, Style(.reverse), "a solid bar cell")
        XCTAssertTrue(screen.cells.allSatisfy { $0.style.fg == .none && $0.style.bg == .none }, "no colour at all")
        XCTAssertTrue(screen.markedLines()[0].contains("[1;7] LIMIT "), screen.markedLines()[0])
    }

    func testGainChips() {
        var gains = Array(repeating: 0.0, count: 10)
        gains[0] = 4.8
        gains[1] = -3.1
        let s = scene(frame(gains: gains), depth: .ansi)
        let g = StudioView(scene: s, compact: false).geometry
        let screen = MeterScreens.screen(s)
        let y = g.liveY + 2
        XCTAssertEqual(screen[g.centre(0), y].style.fg, .ansi(2), "boost is green")
        XCTAssertEqual(screen[g.centre(1), y].style.fg, .ansi(5), "cut is magenta")
        XCTAssertTrue(screen[g.centre(2), y].style.attributes.contains(.dim), "flat is quiet")
        var flashed = scene(frame(gains: gains), depth: .ansi)
        flashed.flash = (1, Watch.flashFrames + MeterScene.flashBlendFrames)
        let chip = MeterScreens.screen(flashed)[g.centre(1), y].style
        XCTAssertEqual(chip, Style(fg: .ansi(5), [.bold, .reverse]), "the edited band's chip is solid")
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
        for look in Look.allCases {
            let s = MeterScreens.scene(frame(gains: gains), cols: 120, rows: 40, look: look)
            XCTAssertEqual(MeterScreens.screen(s).lines().count, 40)
        }
    }

    func testFrameToleratesShortArrays() {
        let short = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: [-20], out: [],
                               peak: -6, limiting: false, gains: [3], preamp: -1.5, enabled: true)
        let g = geometry()
        let lines = MeterScreens.lines(short, cols: 100, rows: 30)
        XCTAssertEqual(lines.count, 30)
        XCTAssertEqual(lines[g.liveY + 2].split(separator: " "), ["+3.0"] + Array(repeating: "0.0", count: 9))
    }

    func testRunLoopExitsOnQ() throws {
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        var keys: [String?] = [nil, "q"]
        let run = MeterHarness.run(lines: Array(repeating: line, count: 5), readKey: { keys.isEmpty ? nil : keys.removeFirst() })
        XCTAssertEqual(run.code, 0)
        XCTAssertEqual(run.drawn.count, 2)
    }

    func testRunLoopExitsOneOnEOF() throws {
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        let run = MeterHarness.run(lines: [line, line], readKey: { nil })
        XCTAssertEqual(run.code, 1)
        XCTAssertEqual(run.drawn.count, 2)
    }

    func testRunClearsOnceAfterResize() throws {
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        var calls = 0
        let run = MeterHarness.run(lines: Array(repeating: line, count: 5),
                                   size: { calls += 1; return calls <= 3 ? (80, 24) : (100, 30) }, readKey: { nil })
        let frames = run.drawn
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(run.whole, [true, false, true, false, false], "the first frame, then only after the resize")
        XCTAssertTrue(frames[2].contains("BE-RCA"))
        XCTAssertTrue(frames[4].components(separatedBy: "\n")[2].hasPrefix("   ╭─ meter"), "the new layout is centred for 100 columns")
    }

    func testRunRendersTinyTerminal() throws {
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        let run = MeterHarness.run(lines: [line], size: { (24, 10) }, readKey: { nil })
        XCTAssertEqual(run.code, 1)
        let drawn = try XCTUnwrap(run.drawn.first)
        XCTAssertTrue(drawn.contains("… widen for all bands"), drawn)
    }
}
