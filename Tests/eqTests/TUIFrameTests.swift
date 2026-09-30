import EQTerm
import XCTest
@testable import eq

/// The watch's keybar and overlays as the loop draws them; the look itself is in TUILookTests.
final class TUIFrameTests: XCTestCase {
    private func frame(solo: SoloRange? = nil) -> MeterFrame {
        let out: [Double] = [-14, -12, -16, -20, -24, -21, -26, -30, -33, -41]
        return MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: out.map { $0 + 2 }, out: out, peak: -6, limiting: false,
                          gains: Config.screenshotCurve, preamp: -4.8, enabled: true, solo: solo)
    }

    private func line(_ f: MeterFrame) throws -> String {
        String(decoding: try MeterFrame.encodeLine(f).dropLast(), as: UTF8.self)
    }

    private func run(_ keys: [String?], frames: Int? = nil, size: (Int, Int) = (100, 30),
                     header: @escaping () -> Watch.Header = { Watch.Header() },
                     edit: @escaping (WatchAction) throws -> Void = { _ in },
                     invalidated: [Bool] = [], mouse: ((Bool) -> Void)? = nil) throws -> (drawn: [String], code: Int32) {
        var queue = keys
        var flags = invalidated
        let text = try line(frame())
        let lines = Array(repeating: text, count: frames ?? keys.count + 1)
        let run = MeterHarness.run(lines: lines, size: { size },
                                   readKey: { queue.isEmpty ? nil : queue.removeFirst() }, edit: edit, header: header,
                                   invalidated: { flags.isEmpty ? false : flags.removeFirst() }, mouse: mouse ?? { _ in })
        return (run.drawn, run.code)
    }

    private func lastRow(_ drawn: String) -> String {
        drawn.components(separatedBy: "\n").last!.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    func testTheKeybarNeverLeaves() throws {
        let keys: [String?] = ["1", "z", "]", "p", nil, "a", "\u{1B}", "b"] + Array(repeating: nil, count: 300)
        let r = try run(keys)
        XCTAssertEqual(r.drawn.count, keys.count + 1, "a key shows on the frame after it")
        for drawn in r.drawn { XCTAssertTrue(lastRow(drawn).hasSuffix(" ?  keys   q  quit"), lastRow(drawn)) }
        XCTAssertTrue(lastRow(r.drawn[2]).contains(" z  zones on"), lastRow(r.drawn[2]))
        XCTAssertTrue(lastRow(r.drawn[3]).contains(" ← →  knob "), "a focus brings its keys: \(lastRow(r.drawn[3]))")
    }

    func testHelpStaysUntilClosed() throws {
        let r = try run([nil, "?", "1", "z", nil, nil, "\u{1B}[B", "q", nil, "h", "\u{1B}", nil, "р", "?", nil])
        let open = r.drawn.map { $0.contains("╭─ keys ") }
        XCTAssertEqual(open, [false, false, true, true, true, true, true, true, false, false, true, false, false, true, false, false])
        XCTAssertEqual(r.code, 1, "q closed the overlay; the source ended, not a quit")
        XCTAssertEqual(lastRow(r.drawn[2]), " ↑↓  scroll   /  filter   Esc  close")
    }

    func testKeysUnderTheHelpDoNotReachTheMeter() throws {
        var edits: [WatchAction] = []
        _ = try run(["?", "1", "+", "p", "\u{1B}", "1"], edit: { edits.append($0) })
        XCTAssertEqual(edits, [.bandStep(0, 0.5)])
    }

    func testHelpScrollStopsAtTheEnd() throws {
        let down = Array(repeating: "j" as String?, count: 120)
        let r = try run(["?"] + down + ["k"], size: (80, 24))
        let positions = r.drawn.compactMap { drawn -> [Int]? in
            drawn.range(of: #" \d+–\d+ of \d+ "#, options: .regularExpression)
                .map { drawn[$0].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        }
        let (visible, total) = (positions[0][1], positions[0][2])
        XCTAssertEqual(positions.first, [1, visible, total])
        XCTAssertEqual(positions.dropLast().last, [total - visible + 1, total, total], "stops where the last line shows")
        XCTAssertEqual(positions.last, [total - visible, total - 1, total], "one k after too many j moves at once")
    }

    func testIOpensTheInstrumentsViewAndEscComesBack() throws {
        let r = try run([nil, "ш", nil, "j", "\u{1B}", nil], header: { Watch.Header(knobs: ["voice": 3]) })
        XCTAssertTrue(r.drawn[2].contains("╭─ instruments "), r.drawn[2])
        XCTAssertNotNil(r.drawn[2].range(of: #"● voice +[┄┼●━]+ +\+3\.0 .+ fundamental +85–255"#, options: .regularExpression), r.drawn[2])
        XCTAssertTrue(r.drawn[3].contains("▸ ● kick"), r.drawn[3])
        XCTAssertTrue(r.drawn[4].contains("▸ ● bass"), "j moves the selection: \(r.drawn[4])")
        XCTAssertFalse(r.drawn[5].contains("╭─ instruments "), "Esc goes back to the meter")
        XCTAssertTrue(r.drawn[5].contains("─ meter ─"), r.drawn[5])
    }

    func testMouseFollowsTheSetting() throws {
        var on = false
        var told: [Bool] = []
        var edits: [WatchAction] = []
        let r = try run([nil, "m", nil, "ь", nil], size: (200, 30), header: { Watch.Header(mouse: on) },
                        edit: { action in edits.append(action); if action == .mouse { on.toggle() } }, mouse: { told.append($0) })
        XCTAssertEqual(edits, [.mouse, .mouse])
        XCTAssertEqual(told, [true, false])
        XCTAssertTrue(lastRow(r.drawn[2]).contains(" m  mouse on"), lastRow(r.drawn[2]))
        XCTAssertTrue(lastRow(r.drawn[4]).contains(" m  mouse off"), lastRow(r.drawn[4]))
        told = []
        on = true
        _ = try run([nil], header: { Watch.Header(mouse: on) }, mouse: { told.append($0) })
        XCTAssertEqual(told, [true], "a saved setting turns reporting on at start")
    }

    func testThePaletteKeyOpensThePalette() throws {
        let r = try run([nil, ";", "zon", "\r", nil])
        XCTAssertTrue(r.drawn[2].contains("╭─ commands "), r.drawn[2])
        XCTAssertTrue(lastRow(r.drawn[2]).contains("Enter  run"), lastRow(r.drawn[2]))
        XCTAssertTrue(r.drawn[3].contains(": zon▏"), r.drawn[3])
        XCTAssertTrue(r.drawn[3].contains("▸ zones"), "the screen's own action matches first: \(r.drawn[3])")
        XCTAssertFalse(r.drawn[4].contains("╭─ commands "))
        XCTAssertTrue(lastRow(r.drawn[4]).contains("z  zones on"), "Enter ran it: \(lastRow(r.drawn[4]))")
    }

    func testGThenALetterGoesThereAndOtherKeysCancel() throws {
        let r = try run([nil, "g", "e", "п", "1", "g", "ь", nil])
        XCTAssertTrue(r.drawn[2].contains("╭─ go to "), r.drawn[2])
        XCTAssertTrue(r.drawn[3].contains("╭─ events "), r.drawn[3])
        XCTAssertFalse(r.drawn[5].contains("╭─ go to "), "1 closed the menu and did nothing else")
        XCTAssertTrue(r.drawn[7].contains("─ meter ─"), "ь is m on a Russian layout: \(r.drawn[7])")
    }

    func testAResumeRedrawsInFullWithoutAFrame() throws {
        var flags = [false, true, false]
        let run = MeterHarness.run(lines: [try line(frame()), "", "", ""], size: { (100, 30) }, readKey: { nil },
                                   invalidated: { flags.isEmpty ? false : flags.removeFirst() })
        XCTAssertEqual(run.drawn.count, 2, "the resume draws once more with no frame")
        XCTAssertTrue(run.whole[1], "the whole screen was lost, so it is cleared first")
    }

    func testAResizeWhileFramesStopRedraws() {
        var sizes = [(80, 24), (80, 24), (80, 24), (100, 30)]
        let text = try! line(frame())
        let run = MeterHarness.run(lines: [text, "", ""], size: { sizes.count > 1 ? sizes.removeFirst() : sizes[0] }, readKey: { nil })
        XCTAssertEqual(run.drawn.count, 2)
        XCTAssertEqual(run.whole, [true, true], "the first frame and the one after the resize are drawn whole")
    }
}
