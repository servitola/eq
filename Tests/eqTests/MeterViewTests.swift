import EQTerm
import XCTest
@testable import eq

/// The meter view draws cells, the bars straight from numbers and every other row through
/// `AnsiText`; the golden files were written from the text frame. These pin the two together:
/// the view's screen holds the golden text, and cell for cell (glyph, width, colour, attribute)
/// what the text frame's escapes paint.
final class MeterViewTests: XCTestCase {
    override func tearDown() { Paint.forced = nil }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tui")

    private func frame(solo: SoloRange? = nil) -> MeterFrame {
        let out: [Double] = [-14, -12, -16, -20, -24, -21, -26, -30, -33, -41]
        return MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: out.map { $0 + 2 }, out: out, peak: -6, limiting: false,
                          gains: Config.screenshotCurve, preamp: -4.8, enabled: true, solo: solo)
    }

    private struct Case {
        var name: String
        var cols: Int, rows: Int
        var strip = false
        var focus: String?
        var modal: WatchModal?
        var prompt: String?
        var listening = false
    }

    private static let goldens = [
        Case(name: "meter-80x24", cols: 80, rows: 24), Case(name: "meter-120x40", cols: 120, rows: 40),
        Case(name: "meter-40x12", cols: 40, rows: 12), Case(name: "meter-40x8", cols: 40, rows: 8),
        Case(name: "help-120x40", cols: 120, rows: 40, modal: .help(scroll: 0)),
        Case(name: "help-80x24", cols: 80, rows: 24, modal: .help(scroll: 0)),
        Case(name: "help-80x24-end", cols: 80, rows: 24, modal: .help(scroll: 99)),
        Case(name: "instruments-100x30", cols: 100, rows: 30, focus: "voice", modal: .instruments(scroll: 0)),
        Case(name: "focus-voice-100x30", cols: 100, rows: 30, strip: true, focus: "voice", listening: true),
        Case(name: "save-as-80x24", cols: 80, rows: 24, prompt: "night"),
    ]

    private func picture(_ c: Case, frame f: MeterFrame? = nil) -> MeterPicture {
        let instrument = c.focus.flatMap(Instruments.named)
        let layout = WatchLayout.fit(cols: c.cols, rows: c.rows,
                                     zones: c.strip ? (instrument == nil ? Instruments.all.count : 1) : 0, bracket: instrument != nil)
        return Watch.picture(f ?? frame(solo: c.listening ? SoloRange(low: 2000, high: 5000) : nil), layout: layout, strip: c.strip,
                             focus: instrument, modal: c.modal, preset: ("favourite", true), knobs: ["voice": 3],
                             prompt: c.prompt.map { TextField($0) }, listening: c.listening)
    }

    private func cells(_ picture: MeterPicture, cols: Int, rows: Int) -> Screen {
        var screen = Screen(width: cols, height: rows)
        picture.draw(into: &screen)
        return screen
    }

    private func text(_ lines: [String], cols: Int, rows: Int) -> Screen {
        var screen = Screen(width: cols, height: rows)
        for (y, line) in lines.enumerated() { AnsiText.draw(line, into: &screen, x: 0, y: y) }
        return screen
    }

    private func trimmed(_ lines: [String]) -> String {
        lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n") + "\n"
    }

    func testTheViewDrawsEveryGoldenScreen() throws {
        Paint.forced = false
        for c in Self.goldens {
            let expected = try String(contentsOf: Self.fixtures.appendingPathComponent(c.name + ".txt"), encoding: .utf8)
            XCTAssertEqual(trimmed(cells(picture(c), cols: c.cols, rows: c.rows).lines()), expected, c.name)
        }
    }

    /// `[codes]…[/]` marks each styled run: the colours and attributes the golden text cannot
    /// show. `EQ_UPDATE_GOLDEN=1` writes them anew.
    func testStyledGoldens() throws {
        Paint.forced = true
        for c in Self.goldens where ["meter-80x24", "focus-voice-100x30", "help-80x24", "save-as-80x24"].contains(c.name) {
            let marked = trimmed(cells(picture(c), cols: c.cols, rows: c.rows).markedLines())
            let url = Self.fixtures.appendingPathComponent(c.name + ".styled.txt")
            if ProcessInfo.processInfo.environment["EQ_UPDATE_GOLDEN"] != nil {
                try marked.write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            XCTAssertEqual(marked, try String(contentsOf: url, encoding: .utf8), c.name)
        }
    }

    func testCellsEqualTheTextFrameAcrossSizesAndStates() {
        let levels: [[Double]] = [
            [-14, -12, -16, -20, -24, -21, -26, -30, -33, -41],
            [-60, -1, -59.5, -3, -45, -6.2, -5.9, -18, -60, 0],
            Array(repeating: -60, count: 10),
        ]
        for colour in [true, false] {
            Paint.forced = colour
            for cols in stride(from: 20, through: 160, by: 7) {
                for rows in stride(from: 6, through: 44, by: 5) {
                    for (n, out) in levels.enumerated() {
                        var f = frame(solo: n == 1 ? SoloRange(low: 85, high: 9000) : nil)
                        f.out = out
                        f.in = out.map { $0 + 3 }
                        f.limiting = n == 1
                        let focus = n == 1 ? "voice" : (n == 2 ? "kick" : nil)
                        let modal: WatchModal? = rows % 3 == 0 ? .help(scroll: cols % 4) : (rows % 3 == 1 ? .instruments(scroll: 0) : nil)
                        let c = Case(name: "", cols: cols, rows: rows, strip: cols % 2 == 0, focus: focus, modal: modal,
                                     prompt: n == 2 ? "club mix" : nil, listening: n == 1)
                        let p = picture(c, frame: f)
                        XCTAssertEqual(cells(p, cols: cols, rows: rows), text(p.lines(), cols: cols, rows: rows),
                                       "\(cols)×\(rows) levels \(n) colour \(colour)")
                    }
                }
            }
        }
    }
}
