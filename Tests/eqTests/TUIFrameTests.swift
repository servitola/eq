import XCTest
@testable import eq

/// Golden screens of the watch with its keybar and overlays, as plain text: `EQ_UPDATE_GOLDEN=1`
/// rewrites the files under Fixtures/tui instead of comparing.
final class TUIFrameTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private struct Source: MeterSource {
        let lines: [String]
        func lines(maxLines: Int?, handle: (String) -> Bool) -> Bool {
            for line in lines { guard handle(line) else { return false } }
            return true
        }
    }

    private func frame(solo: SoloRange? = nil) -> MeterFrame {
        let out: [Double] = [-14, -12, -16, -20, -24, -21, -26, -30, -33, -41]
        return MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: out.map { $0 + 2 }, out: out, peak: -6, limiting: false,
                          gains: Config.screenshotCurve, preamp: -4.8, enabled: true, solo: solo)
    }

    private func line(_ f: MeterFrame) throws -> String {
        String(decoding: try MeterFrame.encodeLine(f).dropLast(), as: UTF8.self)
    }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tui")

    private func assertGolden(_ lines: [String], _ name: String, rows: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(lines.count, rows, "a screen fills the terminal exactly", file: file, line: line)
        let text = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n") + "\n"
        let url = Self.fixtures.appendingPathComponent(name + ".txt")
        if ProcessInfo.processInfo.environment["EQ_UPDATE_GOLDEN"] != nil {
            try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, expected, "\(name):\n\(text)", file: file, line: line)
    }

    private func screen(cols: Int, rows: Int, strip: Bool = false, focus: String? = nil, modal: WatchModal? = nil,
                        prompt: String? = nil, listening: Bool = false) -> [String] {
        let instrument = focus.flatMap(Instruments.named)
        let layout = WatchLayout.fit(cols: cols, rows: rows,
                                     zones: strip ? (instrument == nil ? Instruments.all.count : 1) : 0, bracket: instrument != nil)
        return Watch.frame(frame(solo: listening ? SoloRange(low: 2000, high: 5000) : nil), layout: layout, strip: strip,
                           focus: instrument, modal: modal, preset: ("favourite", true), knobs: ["voice": 3],
                           prompt: prompt, listening: listening)
    }

    func testGoldenMeter() throws {
        try assertGolden(screen(cols: 80, rows: 24), "meter-80x24", rows: 24)
        try assertGolden(screen(cols: 120, rows: 40), "meter-120x40", rows: 40)
        try assertGolden(screen(cols: 40, rows: 12), "meter-40x12", rows: 12)
        try assertGolden(screen(cols: 40, rows: 8), "meter-40x8", rows: 8)
    }

    func testGoldenHelpOverlay() throws {
        try assertGolden(screen(cols: 120, rows: 40, modal: .help(scroll: 0)), "help-120x40", rows: 40)
        try assertGolden(screen(cols: 80, rows: 24, modal: .help(scroll: 0)), "help-80x24", rows: 24)
        try assertGolden(screen(cols: 80, rows: 24, modal: .help(scroll: 99)), "help-80x24-end", rows: 24)
    }

    func testGoldenInstrumentsAndFocus() throws {
        try assertGolden(screen(cols: 100, rows: 30, focus: "voice", modal: .instruments(scroll: 0)), "instruments-100x30", rows: 30)
        try assertGolden(screen(cols: 100, rows: 30, strip: true, focus: "voice", listening: true), "focus-voice-100x30", rows: 30)
        try assertGolden(screen(cols: 80, rows: 24, prompt: "night"), "save-as-80x24", rows: 24)
    }

    private func run(_ keys: [String?], frames: Int? = nil, size: (Int, Int) = (100, 30),
                     header: @escaping () -> Watch.Header = { Watch.Header() },
                     edit: @escaping (WatchAction) throws -> Void = { _ in },
                     invalidated: [Bool] = [], mouse: ((Bool) -> Void)? = nil) throws -> (drawn: [String], code: Int32) {
        var queue = keys
        var flags = invalidated
        var drawn: [String] = []
        let text = try line(frame())
        let lines = Array(repeating: text, count: frames ?? keys.count + 1)
        let code = Watch.run(source: Source(lines: lines), size: { size },
                             emit: { if $0.contains("\u{1B}[H") { drawn.append($0) } },
                             readKey: { queue.isEmpty ? nil : queue.removeFirst() }, edit: edit, header: header,
                             invalidated: { flags.isEmpty ? false : flags.removeFirst() }, mouse: mouse ?? { _ in })
        return (drawn, code)
    }

    private func lastRow(_ drawn: String) -> String {
        drawn.components(separatedBy: "\n").last!.replacingOccurrences(of: "\u{1B}[K\u{1B}[J", with: "")
    }

    func testTheKeybarNeverLeaves() throws {
        let keys: [String?] = ["1", "z", "]", "p", nil, "a", "\u{1B}", "b"] + Array(repeating: nil, count: 300)
        let r = try run(keys)
        XCTAssertEqual(r.drawn.count, keys.count + 1, "a key shows on the frame after it")
        for drawn in r.drawn { XCTAssertTrue(lastRow(drawn).hasSuffix("? keys  q quit"), lastRow(drawn)) }
        XCTAssertTrue(lastRow(r.drawn[2]).contains("z zones on"), lastRow(r.drawn[2]))
        XCTAssertTrue(lastRow(r.drawn[3]).contains("← → knob  l listen off"), "a focus brings its keys: \(lastRow(r.drawn[3]))")
    }

    func testHelpStaysUntilClosed() throws {
        let r = try run([nil, "?", "1", "z", nil, nil, "\u{1B}[B", "q", nil, "h", "\u{1B}", nil, "р", "?", nil])
        let open = r.drawn.map { $0.contains("┌ keys ") }
        XCTAssertEqual(open, [false, false, true, true, true, true, true, true, false, false, true, false, false, true, false, false])
        XCTAssertEqual(r.code, 1, "q closed the overlay; the source ended, not a quit")
        XCTAssertEqual(lastRow(r.drawn[2]), "↑↓ scroll  Esc close")
    }

    func testKeysUnderTheHelpDoNotReachTheMeter() throws {
        var edits: [WatchAction] = []
        _ = try run(["?", "1", "+", "p", "\u{1B}", "1"], edit: { edits.append($0) })
        XCTAssertEqual(edits, [.bandStep(0, 0.5)])
    }

    func testHelpScrollStopsAtTheEnd() throws {
        let down = Array(repeating: "j" as String?, count: 60)
        let r = try run(["?"] + down + ["k"], size: (80, 24))
        let positions = r.drawn.compactMap { drawn in drawn.range(of: #" \d+–\d+ of \d+ "#, options: .regularExpression).map { String(drawn[$0]) } }
        XCTAssertEqual(positions.first, " 1–19 of 31 ")
        XCTAssertTrue(positions.dropLast().last!.hasPrefix(" 13–31 of 31 "), positions.dropLast().last!)
        XCTAssertTrue(positions.last!.hasPrefix(" 12–30 of 31 "), "one k after too many j moves at once: \(positions.last!)")
    }

    func testIOpensTheInstrumentTable() throws {
        let r = try run([nil, "ш", nil, "]", "i", nil], header: { Watch.Header(knobs: ["voice": 3]) })
        XCTAssertTrue(r.drawn[2].contains("┌ instruments "), r.drawn[2])
        XCTAssertTrue(r.drawn[2].contains("voice    +3.0  fundamental 85Hz–255Hz"), r.drawn[2])
        XCTAssertTrue(r.drawn[4].contains("┌ instruments "), "] does nothing under the table: \(r.drawn[4])")
        XCTAssertFalse(r.drawn[4].contains("focus: "))
        XCTAssertFalse(r.drawn[5].contains("┌ instruments "), "i closes what i opened")
    }

    func testMouseFollowsTheSetting() throws {
        var on = false
        var told: [Bool] = []
        var edits: [WatchAction] = []
        let r = try run([nil, "m", nil, "ь", nil], size: (200, 30), header: { Watch.Header(mouse: on) },
                        edit: { action in edits.append(action); if action == .mouse { on.toggle() } }, mouse: { told.append($0) })
        XCTAssertEqual(edits, [.mouse, .mouse])
        XCTAssertEqual(told, [true, false])
        XCTAssertTrue(lastRow(r.drawn[2]).contains("m mouse on"), lastRow(r.drawn[2]))
        XCTAssertTrue(lastRow(r.drawn[4]).contains("m mouse off"), lastRow(r.drawn[4]))
        told = []
        on = true
        _ = try run([nil], header: { Watch.Header(mouse: on) }, mouse: { told.append($0) })
        XCTAssertEqual(told, [true], "a saved setting turns reporting on at start")
    }

    func testThePaletteKeyIsKeptButSaysSo() throws {
        let r = try run([nil, ";", nil])
        XCTAssertTrue(r.drawn[2].contains(Watch.paletteNote), r.drawn[2])
    }

    func testAResumeRedrawsInFullWithoutAFrame() throws {
        var queue: [String?] = []
        var flags = [false, true, false]
        var drawn: [String] = []
        _ = Watch.run(source: Source(lines: [try line(frame()), "", "", ""]), size: { (100, 30) },
                      emit: { if $0.contains("\u{1B}[H") { drawn.append($0) } },
                      readKey: { queue.isEmpty ? nil : queue.removeFirst() },
                      invalidated: { flags.isEmpty ? false : flags.removeFirst() })
        XCTAssertEqual(drawn.count, 2, "the idle wake-up after the resume draws once more")
        XCTAssertTrue(drawn[1].hasPrefix("\u{1B}[2J"), "the whole screen was lost, so it is cleared first")
    }

    func testAResizeWhileFramesStopRedraws() {
        var queue: [String?] = []
        var sizes = [(80, 24), (80, 24), (80, 24), (100, 30)]
        var drawn: [String] = []
        let text = try! line(frame())
        _ = Watch.run(source: Source(lines: [text, "", ""]), size: { sizes.count > 1 ? sizes.removeFirst() : sizes[0] },
                      emit: { if $0.contains("\u{1B}[H") { drawn.append($0) } },
                      readKey: { queue.isEmpty ? nil : queue.removeFirst() })
        XCTAssertEqual(drawn.count, 2)
        XCTAssertTrue(drawn[1].hasPrefix("\u{1B}[2J"))
    }
}
