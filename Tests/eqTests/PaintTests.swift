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
        XCTAssertTrue(plain.components(separatedBy: "\n")[1].contains("▅"))
        XCTAssertFalse(plain.contains("\u{1B}"))
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
