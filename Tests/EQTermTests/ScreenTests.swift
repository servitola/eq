import EQTerm
import XCTest

final class ScreenTests: XCTestCase {
    override func setUp() { TerminalText.useUTF8Widths() }

    func testPutCountsColumnsPerGraphemeAndNeverSplitsAWideGlyph() {
        var screen = Screen(width: 6, height: 1)
        XCTAssertEqual(screen.put("耳机耳", x: 0, y: 0), 6)
        XCTAssertEqual(screen.lines(), ["耳机耳"])
        XCTAssertTrue(screen[1, 0].isContinuation)
        var cut = Screen(width: 5, height: 1)
        cut.put("耳机耳机", x: 0, y: 0)
        XCTAssertEqual(cut.lines(), ["耳机 "], "the third glyph would straddle the edge")
        var accent = Screen(width: 3, height: 1)
        accent.put("e\u{301}x", x: 0, y: 0)
        XCTAssertEqual(accent[0, 0].text, "e\u{301}")
        XCTAssertEqual(accent[1, 0].text, "x")
    }

    func testOverwritingHalfAWideGlyphBlanksTheOtherHalf() {
        var screen = Screen(width: 4, height: 1)
        screen.put("中中", x: 0, y: 0)
        screen.put("a", x: 1, y: 0)
        XCTAssertEqual(screen.lines(), [" a中"])
        screen.put("b", x: 2, y: 0)
        XCTAssertEqual(screen.lines(), [" ab "])
    }

    func testAnsiTextReadsTheSGRPaintWrites() {
        var screen = Screen(width: 12, height: 1)
        AnsiText.draw("a\u{1B}[32mbc\u{1B}[0m\u{1B}[1;93md\u{1B}[0m\u{1B}[38;5;208me\u{1B}[48;2;1;2;3mf\u{1B}[Kg", into: &screen, x: 0, y: 0)
        XCTAssertEqual(screen.lines(), ["abcdefg     "])
        XCTAssertEqual(screen[0, 0].style, .plain)
        XCTAssertEqual(screen[1, 0].style, Style(fg: .ansi(2)))
        XCTAssertEqual(screen[3, 0].style, Style(fg: .ansi(11), .bold))
        XCTAssertEqual(screen[4, 0].style, Style(fg: .indexed(208)))
        XCTAssertEqual(screen[5, 0].style, Style(fg: .indexed(208), bg: .rgb(1, 2, 3)))
        XCTAssertEqual(screen[6, 0].style, screen[5, 0].style, "ESC [ K is skipped, not drawn")
    }

    func testAnsiTextKeepsAClusterThatStartsWithASCII() {
        var screen = Screen(width: 4, height: 1)
        AnsiText.draw("1\u{FE0F}\u{20E3}x", into: &screen, x: 0, y: 0)
        XCTAssertEqual(screen[0, 0].text, "1\u{FE0F}\u{20E3}")
        XCTAssertEqual(screen[2, 0].text, "x")
    }

    func testMarkedLinesShowStyledRuns() {
        var screen = Screen(width: 8, height: 1)
        screen.put("ab", x: 0, y: 0, style: Style(fg: .ansi(2), .bold))
        screen.put("c", x: 3, y: 0, style: .reverse)
        XCTAssertEqual(screen.markedLines(), ["[1;32]ab[/] [7]c[/]    "])
    }

    func testTruncatedEndsInAnEllipsis() {
        XCTAssertEqual(TerminalText.truncated("preset favourite", columns: 8), "preset …")
        XCTAssertEqual(TerminalText.truncated("short", columns: 8), "short")
    }

    func testLayoutSplitsFixedMinFillAndPercent() {
        let area = Rect(x: 0, y: 0, width: 100, height: 24)
        XCTAssertEqual(area.split(.vertical, [.fixed(1), .fill(1), .fixed(1), .fixed(1)]).map(\.height), [1, 21, 1, 1])
        XCTAssertEqual(area.split(.horizontal, [.percent(30), .fill(1), .fill(2)]).map(\.width), [30, 23, 47])
        XCTAssertEqual(area.split(.horizontal, [.min(10), .min(20)]).map(\.width), [45, 55], "mins share what no fill takes")
        let tight = Rect(x: 0, y: 0, width: 10, height: 3).split(.vertical, [.fixed(2), .fixed(2), .fill(1)])
        XCTAssertEqual(tight.map(\.height), [2, 1, 0], "too little room takes from the end")
        XCTAssertEqual(tight.map(\.y), [0, 2, 3])
        XCTAssertEqual(area.centered(width: 20, height: 4), Rect(x: 40, y: 10, width: 20, height: 4))
    }
}
