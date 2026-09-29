import EQTerm
import XCTest

final class SwatchTests: XCTestCase {
    func testDepthDetection() {
        let cases: [([String: String], ColorDepth, String)] = [
            (["TERM": "xterm-256color", "COLORTERM": "truecolor"], .truecolor, "the user's stack"),
            (["TERM": "tmux-256color", "COLORTERM": "truecolor"], .truecolor, "tmux exports COLORTERM and converts itself"),
            (["TERM": "screen", "COLORTERM": "24bit"], .truecolor, "24bit is the other spelling"),
            (["TERM": "xterm-direct"], .truecolor, "-direct terminfo"),
            (["TERM": "xterm-256color"], .indexed, "256 without COLORTERM"),
            (["TERM": "xterm"], .ansi, "sixteen otherwise"),
            ([:], .ansi, "no TERM at all"),
            (["TERM": "dumb", "COLORTERM": "truecolor"], .none, "dumb beats everything"),
            (["TERM": "xterm-256color", "COLORTERM": "truecolor", "NO_COLOR": "1"], .none, "NO_COLOR beats everything"),
            (["TERM": "xterm-256color", "NO_COLOR": ""], .indexed, "an empty NO_COLOR is not set"),
        ]
        for (env, expected, why) in cases { XCTAssertEqual(ColorDepth.detect(env), expected, why) }
    }

    /// tmux's `colour_find_rgb`, checked against the values it gives.
    func testNearest256UsesTheRealCubeLevelsAndTheGreyRamp() {
        XCTAssertEqual(Swatch.nearest256(0, 0, 0), 16)
        XCTAssertEqual(Swatch.nearest256(255, 255, 255), 231)
        let exact: UInt8 = 16 + 36 + 12 + 3
        XCTAssertEqual(Swatch.nearest256(0x5F, 0x87, 0xAF), exact, "exact cube levels map straight in")
        XCTAssertEqual(Swatch.nearest256(0x24, 0x26, 0x2B), 235, "the ink ground is a grey")
        XCTAssertEqual(Swatch.nearest256(0x8A, 0xA8, 0xFF), 111, "the ink accent")
        XCTAssertEqual(Swatch.nearest256(0x63, 0xD9, 0x9E), 79, "the ink boost")
        XCTAssertEqual(Swatch(0xF27FBC).index, 211, "the ink cut")
        XCTAssertEqual(Swatch(0x123456, index: 22).index, 22, "an index given by hand wins")
    }

    func testStylePerDepth() {
        let boost = Swatch(0x63D99E, sgr: 32)
        let chip = Swatch(0x2F3544, background: 100)
        let dim = Swatch(0x7C859A, .dim)
        XCTAssertEqual(ColorDepth.truecolor.style(boost, chip), Style(fg: .rgb(0x63, 0xD9, 0x9E), bg: .rgb(0x2F, 0x35, 0x44)))
        XCTAssertEqual(ColorDepth.indexed.style(boost, chip), Style(fg: .indexed(79), bg: .indexed(Swatch.nearest256(0x2F, 0x35, 0x44))))
        XCTAssertEqual(ColorDepth.ansi.style(boost, chip), Style(fg: .ansi(2), bg: .ansi(8)))
        XCTAssertEqual(ColorDepth.ansi.style(dim), Style(.dim), "a stand-in may be only an attribute")
        XCTAssertEqual(ColorDepth.none.style(boost, chip, .bold), Style(.bold), "no colour: attributes only")
        XCTAssertEqual(ColorDepth.none.style(nil, boost, solid: true), Style(.reverse), "a solid cell turns to reverse video")
        let solo = Swatch(0xFFD166, sgr: 93)
        XCTAssertEqual(ColorDepth.ansi.style(Swatch(0x10131A), solo, .bold, solid: true), Style(fg: .ansi(11), [.bold, .reverse]),
                       "a chip whose background has no 16-colour code shows its colour reversed")
        XCTAssertEqual(ColorDepth.ansi.style(Swatch(0xEEF1F6, .bold), nil, .dim), Style(.bold), "bold wins over dim")
    }

    func testMixing() {
        let a = Swatch(0x000000, sgr: 32), b = Swatch(0xFFFFFF)
        let half = a.mixed(toward: b, 0.5)
        XCTAssertEqual([half.r, half.g, half.b], [128, 128, 128])
        XCTAssertEqual(half.ansi, 2, "the 16-colour stand-in stays")
        XCTAssertEqual(a.mixed(toward: b, 0), a)
    }
}
