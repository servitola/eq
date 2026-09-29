import EQTerm
import XCTest

/// A terminal just big enough to check the renderer: cursor moves, CUF, SGR, clear, text.
struct Emulator {
    var screen: Screen
    var x = 0, y = 0
    var pen = Style.plain

    init(width: Int, height: Int) { screen = Screen(width: width, height: height) }

    mutating func apply(_ bytes: [UInt8]) {
        let text = String(decoding: bytes, as: UTF8.self)
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            guard c == "\u{1B}" else {
                let w = TerminalText.width(of: c)
                screen.set(x, y, Cell(String(c), width: UInt8(w), style: pen))
                x += w
                continue
            }
            guard chars.popFirst() == "[" else { continue }
            var parameters = ""
            while let p = chars.first, let a = p.asciiValue, (0x20...0x3F).contains(a) { parameters.append(chars.removeFirst()) }
            let final = chars.popFirst()
            let numbers = parameters.split(separator: ";").map { Int($0) ?? 0 }
            switch final {
            case "H":
                y = (numbers.first ?? 1) - 1
                x = (numbers.count > 1 ? numbers[1] : 1) - 1
            case "C": x += max(numbers.first ?? 1, 1)
            case "J": screen.fill(screen.area)
            case "m": pen = numbers.first == 0 || numbers.isEmpty ? Style.plain.applying(Array(numbers.dropFirst())) : pen.applying(numbers)
            default: break
            }
        }
    }
}

final class RendererTests: XCTestCase {
    override func setUp() { TerminalText.useUTF8Widths() }

    private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    func testTheFirstFrameClearsAndWritesOnlyWhatIsNotBlank() {
        var renderer = Renderer()
        var screen = Screen(width: 10, height: 2)
        screen.put("ab", x: 2, y: 1, style: Style(fg: .ansi(2)))
        XCTAssertEqual(text(renderer.render(screen)), "\u{1B}[?2026h\u{1B}[H\u{1B}[2J\u{1B}[2;3H\u{1B}[32mab\u{1B}[39m\u{1B}[?2026l")
    }

    func testAnUnchangedFrameWritesNothingAndAChangeOnlyItself() {
        var renderer = Renderer()
        var screen = Screen(width: 10, height: 3)
        screen.put("hello", x: 0, y: 0)
        _ = renderer.render(screen)
        XCTAssertEqual(renderer.render(screen), [], "not even the brackets")
        screen.put("j", x: 0, y: 0)
        XCTAssertEqual(text(renderer.render(screen)), "\u{1B}[?2026h\u{1B}[1;1Hj\u{1B}[?2026l")
    }

    func testAShortGapIsRewrittenALongOneJumped() {
        var renderer = Renderer()
        var screen = Screen(width: 20, height: 1)
        screen.put("abcdefghijklmnopqrst", x: 0, y: 0)
        _ = renderer.render(screen)
        screen.put("A", x: 0, y: 0)
        screen.put("C", x: 2, y: 0)
        screen.put("T", x: 19, y: 0)
        XCTAssertEqual(text(renderer.render(screen)), "\u{1B}[?2026h\u{1B}[1;1HAbC\u{1B}[16CT\u{1B}[?2026l")
    }

    func testAStyleOnlyChangeRewritesTheCellAndThePenCarriesOver() {
        var renderer = Renderer()
        var screen = Screen(width: 6, height: 2)
        screen.put("ab", x: 0, y: 0, style: .bold)
        screen.put("cd", x: 0, y: 1, style: .bold)
        _ = renderer.render(screen)
        screen.put("ab", x: 0, y: 0, style: Style(fg: .ansi(1), .bold))
        screen.put("cd", x: 0, y: 1, style: Style(fg: .ansi(1), .bold))
        XCTAssertEqual(text(renderer.render(screen)), "\u{1B}[?2026h\u{1B}[1;1H\u{1B}[1;31mab\u{1B}[2;1Hcd\u{1B}[0m\u{1B}[?2026l",
                       "one pen for both rows; the reset only because bold goes off at the end")
    }

    func testAChangedHalfOfAWideGlyphRewritesTheWholeGlyph() {
        var renderer = Renderer()
        var screen = Screen(width: 6, height: 1)
        screen.put("a中b", x: 0, y: 0)
        _ = renderer.render(screen)
        screen.put("中", x: 1, y: 0, style: .bold)
        XCTAssertEqual(text(renderer.render(screen)), "\u{1B}[?2026h\u{1B}[1;2H\u{1B}[1m中\u{1B}[0m\u{1B}[?2026l")
    }

    func testAResizeOrAnInvalidateDrawsWhole() {
        var renderer = Renderer()
        var screen = Screen(width: 4, height: 1)
        screen.put("ab", x: 0, y: 0)
        _ = renderer.render(screen)
        renderer.invalidate()
        XCTAssertTrue(text(renderer.render(screen)).contains(Renderer.clear))
        XCTAssertTrue(text(renderer.render(Screen(width: 5, height: 1))).contains(Renderer.clear))
    }

    func testWithoutSynchronizedUpdatesThereAreNoBrackets() {
        var renderer = Renderer()
        renderer.synchronized = false
        var screen = Screen(width: 4, height: 1)
        screen.put("a", x: 0, y: 0)
        XCTAssertEqual(text(renderer.render(screen)), "\u{1B}[H\u{1B}[2J\u{1B}[1;1Ha")
    }

    /// Random screens one after another: what the bytes do to a terminal is the screen itself.
    func testTheBytesReproduceEveryScreen() {
        var generator = SystemRandomNumberGenerator()
        let glyphs = ["a", "b", " ", "█", "▁", "中", "é", "-"]
        let styles = [Style.plain, .bold, .dim, Style(fg: .ansi(2)), Style(fg: .ansi(13), .bold), Style(fg: .indexed(208), bg: .rgb(9, 9, 9)),
                      Style(bg: .ansi(4)), .reverse]
        for _ in 0..<20 {
            let width = Int.random(in: 1...30, using: &generator), height = Int.random(in: 1...6, using: &generator)
            var renderer = Renderer()
            var terminal = Emulator(width: width, height: height)
            var screen = Screen(width: width, height: height)
            for _ in 0..<15 {
                for _ in 0..<Int.random(in: 0...40, using: &generator) {
                    screen.put(glyphs.randomElement(using: &generator)!, x: Int.random(in: 0..<width, using: &generator),
                               y: Int.random(in: 0..<height, using: &generator), style: styles.randomElement(using: &generator)!)
                }
                terminal.apply(renderer.render(screen))
                XCTAssertEqual(terminal.screen, screen)
                XCTAssertEqual(terminal.pen, .plain, "every frame ends on a plain pen")
            }
        }
    }
}
