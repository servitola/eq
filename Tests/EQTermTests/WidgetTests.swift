import EQTerm
import XCTest

final class WidgetTests: XCTestCase {
    override func setUp() { TerminalText.useUTF8Widths() }

    private func draw(_ width: Int, _ height: Int, _ body: (inout Screen) -> Void) -> [String] {
        var screen = Screen(width: width, height: height)
        body(&screen)
        return screen.lines()
    }

    func testSpansCutWithAnEllipsis() {
        XCTAssertEqual(draw(8, 1) { $0.draw([Span("preset "), Span("favourite", .bold)], in: $0.area) }, ["preset …"])
        XCTAssertEqual(draw(8, 1) { $0.draw([Span("ok")], in: $0.area) }, ["ok      "])
    }

    func testBarsGrowFromTheBottomInEighths() {
        let lines = draw(5, 3) { Bars.draw([1, 0.5, 0.25 + 1.0 / 24], styles: [], into: &$0, rect: $0.area, barWidth: 1, pitch: 2) }
        XCTAssertEqual(lines, ["█    ", "█ ▅  ", "█ █ █"])
    }

    func testGaugeShowsTheRatioAndItsLabel() {
        var screen = Screen(width: 10, height: 1)
        Gauge.draw(0.5, into: &screen, rect: screen.area)
        XCTAssertEqual(screen.lines(), ["███50%░░░░"])
        XCTAssertEqual(screen[3, 0].style, .reverse)
    }

    func testListScrollsTheSelectionIntoViewAndReversesIt() {
        var state = ListState()
        state.move(5, count: 10, visible: 3)
        XCTAssertEqual(state, ListState(selected: 5, offset: 3))
        state.move(-4, count: 10, visible: 3)
        XCTAssertEqual(state, ListState(selected: 1, offset: 1))
        state.move(99, count: 10, visible: 3)
        XCTAssertEqual(state, ListState(selected: 9, offset: 7))
        var screen = Screen(width: 4, height: 2)
        ListView.draw((0..<10).map { [Span("i\($0)")] }, state: ListState(selected: 3, offset: 2), into: &screen, rect: screen.area)
        XCTAssertEqual(screen.lines(), ["i2  ", "i3  "])
        XCTAssertTrue(screen[3, 1].style.attributes.contains(.reverse), "the whole row, not only its text")
        XCTAssertFalse(screen[0, 0].style.attributes.contains(.reverse))
    }

    func testTableSharesTheWidthByConstraint() {
        var screen = Screen(width: 16, height: 3)
        TableView.draw([.init("name", .fixed(6)), .init("gain", .fill(1))], rows: [[Span("kick"), Span("+3.0")], [Span("voice"), Span("-1.5")]],
                       state: ListState(selected: 1), into: &screen, rect: screen.area)
        XCTAssertEqual(screen.lines(), ["name   gain     ", "kick   +3.0     ", "voice  -1.5     "])
        XCTAssertTrue(screen[0, 0].style.attributes.contains(.bold))
        XCTAssertTrue(screen[0, 2].style.attributes.contains(.reverse))
    }

    func testTabsMarkTheCurrentOneAndReportWhereEachIs() {
        var screen = Screen(width: 20, height: 1)
        let hits = Tabs.draw(["Meter", "Tune", "Presets"], selected: 1, into: &screen, rect: screen.area)
        XCTAssertEqual(screen.lines(), ["Meter  Tune  Presets"])
        XCTAssertEqual(hits, [0..<5, 7..<11, 13..<20])
        XCTAssertEqual(screen[7, 0].style.attributes, [.bold, .underline, .reverse])
    }

    func testKeybarDropsByRankAndKeepsThePinned() {
        let entries = [Keybar.Entry(key: "q", text: "quit", rank: 0), Keybar.Entry(key: "z", text: "zones", rank: 3),
                       Keybar.Entry(key: "1…0", text: "band", rank: 1), Keybar.Entry(key: "?", text: "keys", rank: 0)]
        XCTAssertEqual(Keybar.fit(entries, width: 80).map(\.key), ["1…0", "z", "q", "?"])
        XCTAssertEqual(Keybar.fit(entries, width: 24).map(\.key), ["1…0", "q", "?"])
        XCTAssertEqual(Keybar.fit(entries, width: 8).map(\.key), ["?"])
        XCTAssertEqual(draw(30, 1) { Keybar.draw(entries, into: &$0, rect: $0.area) }, ["1…0 band  q quit  ? keys      "])
    }

    func testModalCentresScrollsAndSaysWhichPartShows() {
        let lines = draw(20, 6) { screen in
            Modal.draw(title: "keys", lines: (1...9).map { [Span("line \($0)")] }, scroll: 2, into: &screen, area: screen.area)
        }
        XCTAssertEqual(lines, ["    ┌ keys ────┐    ",
                               "    │ line 3   │    ",
                               "    │ line 4   │    ",
                               "    │ line 5   │    ",
                               "    │ line 6   │    ",
                               "    └ 3–6 of 9 ┘    "], "the box widens for its position")
    }

    func testTextFieldEditsLikeALineEditor() {
        var field = TextField()
        for c in "club mix" { XCTAssertEqual(field.handle(KeyPress(.char(c))), .editing) }
        XCTAssertEqual(field.handle(KeyPress(.char("\u{17}"))), .editing)
        XCTAssertEqual(field.text, "club ")
        _ = field.handle(KeyPress(.left))
        _ = field.handle(KeyPress(.left))
        _ = field.handle(.paste("s\n"))
        XCTAssertEqual(field.text, "clusb ", "a paste goes in at the cursor, newlines dropped")
        XCTAssertEqual(field.display(width: 20), "clus▏b ")
        _ = field.handle(KeyPress(.char("\u{7F}")))
        XCTAssertEqual(field.text, "club ")
        XCTAssertEqual(field.handle(KeyPress(.up)), .ignored)
        XCTAssertEqual(field.handle(KeyPress(.char("\u{03}"))), .ignored)
        _ = field.handle(KeyPress(.end))
        XCTAssertEqual(field.handle(KeyPress(.char("\n"))), .submit("club "))
        XCTAssertEqual(field.handle(KeyPress(.esc)), .cancel)
        XCTAssertEqual(TextField("a long preset name").display(width: 6), " name▏", "the cursor end stays in sight")
    }
}
