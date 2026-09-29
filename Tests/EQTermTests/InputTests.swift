import EQTerm
import XCTest

final class InputTests: XCTestCase {
    private func events(_ reads: [String]) -> [InputEvent] {
        var decoder = InputDecoder()
        return reads.flatMap { decoder.feed(Array($0.utf8)) }
    }

    private func key(_ code: KeyCode, _ modifiers: Modifiers = []) -> InputEvent { .key(KeyPress(code, modifiers)) }

    func testModifiedArrowsHomeEndAndFunctionKeys() {
        XCTAssertEqual(events(["\u{1B}[1;2A\u{1B}[1;5C\u{1B}[1;3D\u{1B}[H\u{1B}OF"]),
                       [key(.up, .shift), key(.right, .ctrl), key(.left, .alt), key(.home), key(.end)])
        XCTAssertEqual(events(["\u{1B}OP\u{1B}[15~\u{1B}[24~\u{1B}[1;2P"]),
                       [key(.function(1)), key(.function(5)), key(.function(12)), key(.function(1), .shift)])
        XCTAssertEqual(events(["\u{1B}[5~\u{1B}[6~\u{1B}[3~\u{1B}[2~\u{1B}[Z"]),
                       [key(.pageUp), key(.pageDown), key(.delete), key(.insert), key(.backTab, .shift)])
        XCTAssertEqual(events(["\u{1B}x"]), [key(.char("x"), .alt)])
    }

    func testSGRMouse() {
        XCTAssertEqual(events(["\u{1B}[<0;10;5M\u{1B}[<0;10;5m"]),
                       [.mouse(Mouse(.press, button: .left, x: 9, y: 4)), .mouse(Mouse(.release, button: .left, x: 9, y: 4))])
        XCTAssertEqual(events(["\u{1B}[<64;1;1M\u{1B}[<65;2;3M\u{1B}[<66;1;1M"]),
                       [.mouse(Mouse(.wheelUp, x: 0, y: 0)), .mouse(Mouse(.wheelDown, x: 1, y: 2))], "the horizontal wheel is dropped")
        XCTAssertEqual(events(["\u{1B}[<34;4;4M\u{1B}[<18;1;1M"]),
                       [.mouse(Mouse(.drag, button: .right, x: 3, y: 3)), .mouse(Mouse(.press, button: .right, x: 0, y: 0, modifiers: .ctrl))])
        XCTAssertEqual(events(["\u{1B}[<3", "5;7;8M"]), [.mouse(Mouse(.move, x: 6, y: 7))], "split across reads")
    }

    func testBracketedPasteIsOneEventAcrossReads() {
        XCTAssertEqual(events(["a\u{1B}[200~club", " mix\nq", "\u{1B}[201~b"]),
                       [key(.char("a")), .paste("club mix\nq"), key(.char("b"))], "q inside a paste is text, not a quit")
    }

    func testFocusReportsAndModeAnswers() {
        XCTAssertEqual(events(["\u{1B}[I\u{1B}[O\u{1B}[?2026;2$y"]), [.focus(true), .focus(false), .modeReport(mode: 2026, value: 2)])
    }

    func testALoneEscWaitsForTheNextReadThenIsEsc() {
        var decoder = InputDecoder()
        XCTAssertEqual(decoder.feed(Array("]\u{1B}".utf8)), [key(.char("]"))])
        XCTAssertTrue(decoder.holdsEscape)
        XCTAssertEqual(decoder.feed([]), [key(.esc)])
        XCTAssertFalse(decoder.holdsEscape)
        XCTAssertEqual(decoder.feed(Array("\u{1B}[".utf8)), [])
        XCTAssertEqual(decoder.feed([]), [key(.esc), key(.char("["))], "typed, since a terminal sends a whole sequence at once")
    }
}
