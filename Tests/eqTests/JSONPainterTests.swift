import XCTest
@testable import eq

final class JSONPainterTests: XCTestCase {
    override func tearDown() { Paint.forced = nil }

    private func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private func ink(_ code: Int, _ text: String) -> String { "\u{1B}[\(code)m\(text)\u{1B}[0m" }

    func testTokenColours() {
        let json = CLI.encode(["name": AnyEncodable("JBL"), "gain": AnyEncodable(-3.5), "on": AnyEncodable(true),
                               "off": AnyEncodable(false), "preset": AnyEncodable(String?.none), "bands": AnyEncodable([1, 2])])
        let painted = JSONPainter.paint(json)
        XCTAssertTrue(painted.contains(ink(34, "\"name\"") + " " + ink(2, ":") + " " + ink(32, "\"JBL\"")), painted)
        XCTAssertTrue(painted.contains(ink(33, "-3.5")), painted)
        XCTAssertTrue(painted.contains(ink(36, "true")), painted)
        XCTAssertTrue(painted.contains(ink(36, "false")), painted)
        XCTAssertTrue(painted.contains(ink(2, "null")), painted)
        XCTAssertTrue(painted.contains(ink(2, "{")) && painted.contains(ink(2, "[")) && painted.contains(ink(2, ",")), painted)
        XCTAssertEqual(strip(painted), json)
    }

    func testTrickyStringsRoundTrip() throws {
        let values = ["say \"hi\": ok", "back\\slash\\", "a:b,c{d}[e]", "Überhörer · 16 kHz ✓", "\u{301}combining first", "", "true", "-12"]
        for value in values {
            let json = CLI.encode(["k\"ey:": value, "path": "/Users/x/.config/eq/eq.json"])
            let painted = JSONPainter.paint(json)
            XCTAssertEqual(strip(painted), json, value)
            let quoted = CLI.encode([value]).dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(painted.contains(ink(32, quoted)), "\(value): \(painted)")
            XCTAssertTrue(painted.contains(ink(34, "\"k\\\"ey:\"")), painted)
        }
    }

    func testCommandJSONIsPaintedOnlyWhenColourIsOn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-json-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-27" })
        Paint.forced = false
        _ = CLI.run(["init"], context: context)
        let plain = CLI.run(["devices", "--json"], context: context).output
        XCTAssertFalse(plain.contains("\u{1B}"))
        Paint.forced = true
        let painted = CLI.run(["devices", "--json"], context: context).output
        XCTAssertTrue(painted.contains(ink(34, "\"devices\"")), painted)
        XCTAssertEqual(strip(painted), plain)
        let error = CLI.run(["set", "99hz", "1", "--json"], context: context).output
        XCTAssertTrue(error.contains(ink(34, "\"error\"")), error)
    }
}
