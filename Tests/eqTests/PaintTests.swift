import XCTest
@testable import eq

final class PaintTests: XCTestCase {
    override func tearDown() { Paint.forced = nil }

    func testDisabledIsPlain() {
        Paint.forced = false
        XCTAssertEqual(Paint.ink(.green, "+4.8"), "+4.8")
        XCTAssertEqual(Paint.spark([0, 12, -12]), "▄█▁")
    }

    func testEnabledWrapsWithSGR() {
        Paint.forced = true
        XCTAssertEqual(Paint.ink(.green, "+4.8"), "\u{1B}[32m+4.8\u{1B}[0m")
        XCTAssertEqual(Paint.gain(4.8), .green)
        XCTAssertEqual(Paint.gain(-3.1), .magenta)
        XCTAssertEqual(Paint.gain(0), .dim)
        XCTAssertTrue(Paint.spark([6]).contains("\u{1B}[32m"))
    }

    func testTableGainsArePaintedAndSparkRowPresent() {
        Paint.forced = true
        let text = Table.profile(Profile(name: "X", preamp: 0, bands: Config.screenshotCurve), header: "X")
        XCTAssertTrue(text.contains("\u{1B}[32m  +4.8"), text)
        XCTAssertTrue(text.contains("\u{1B}[35m  -3.1"), text)
        XCTAssertEqual(text.components(separatedBy: "\n").count, 4)
        Paint.forced = false
        let plain = Table.profile(Profile(name: "X", preamp: 0, bands: Config.screenshotCurve), header: "X")
        XCTAssertEqual(plain.components(separatedBy: "\n").count, 3)
        XCTAssertFalse(plain.contains("▅"))
        XCTAssertFalse(plain.contains("\u{1B}"))
    }

    func testHotLevelsUseBrightShades() {
        Paint.forced = true
        XCTAssertEqual(Paint.level(.green, hot: true), .brightGreen)
        XCTAssertEqual(Paint.level(.magenta, hot: true), .brightMagenta)
        XCTAssertEqual(Paint.level(.yellow, hot: true), .brightYellow)
        XCTAssertEqual(Paint.level(.dim, hot: true), .dim)
        XCTAssertEqual(Paint.level(.green, hot: false), .green)
        XCTAssertEqual(Paint.ink(.brightGreen, "x"), "\u{1B}[92mx\u{1B}[0m")
        XCTAssertEqual(Paint.ink(.brightMagenta, "x"), "\u{1B}[95mx\u{1B}[0m")
        XCTAssertEqual(Paint.ink(.brightYellow, "x"), "\u{1B}[93mx\u{1B}[0m")
    }

    func testTableRowsTakeWidthAndShortLabels() {
        Paint.forced = false
        XCTAssertEqual(Table.labelsRow(width: 3, short: true), " 32 64125250500 1k 2k 4k 8k16k")
        XCTAssertEqual(Table.labelsRow(width: 4, short: true, columns: 3), "  32  64 125")
        XCTAssertEqual(Table.labelsRow(width: 8), Config.bandLabels.map { $0.leftPadded(to: 8) }.joined())
        XCTAssertEqual(Table.gainsRow([4.8, -12, 0, .nan], width: 4), "  +5 -12   0   0")
        XCTAssertEqual(Table.gainsRow([4.8], width: 7), "   +4.8")
        XCTAssertEqual(Table.labelsRow(), Table.labelsRow(width: 6, short: false))
    }

    func testStateInks() {
        XCTAssertEqual(Paint.state(.running), .green)
        XCTAssertEqual(Paint.state(.bypassed), .yellow)
        XCTAssertEqual(Paint.state(.starting), .yellow)
        XCTAssertEqual(Paint.state(.failed), .red)
        XCTAssertEqual(Paint.state(.noPermission), .red)
    }

    func testEnvironmentDecision() {
        Paint.forced = nil
        setenv("NO_COLOR", "1", 1); defer { unsetenv("NO_COLOR") }
        XCTAssertFalse(Paint.enabled)
    }
}
