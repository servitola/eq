import XCTest
@testable import eq

final class HelpTests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-help-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-27" })
        context.width = { _ in 80 }
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    func testNoLineExceedsTheWidth() {
        for width in 40...200 {
            let plain = HelpRenderer.render(width: width, paint: false)
            for line in plain.components(separatedBy: "\n") {
                XCTAssertLessThanOrEqual(line.count, width, "width \(width): \(line)")
            }
            XCTAssertEqual(strip(HelpRenderer.render(width: width, paint: true)), plain, "width \(width)")
        }
    }

    func testTinyWidthsDoNotCrash() {
        for width in [-5, 0, 1, 10, 19] { XCTAssertFalse(HelpRenderer.render(width: width, paint: false).isEmpty) }
    }

    func testPlainHasNoEscapesAndPaintedDoes() {
        XCTAssertFalse(HelpRenderer.render(width: 100, paint: false).contains("\u{1B}"))
        let painted = HelpRenderer.render(width: 100, paint: true)
        XCTAssertTrue(painted.contains("\u{1B}[2mlook\u{1B}[0m"))
        XCTAssertTrue(painted.contains("\u{1B}[1mset\u{1B}[0m"))
        XCTAssertTrue(painted.contains("\u{1B}[36m--device\u{1B}[0m"))
        XCTAssertTrue(painted.contains("\u{1B}[33mDEVICE\u{1B}[0m"))
        XCTAssertTrue(painted.contains("\u{1B}[33m<band>\u{1B}[0m"))
    }

    func testDescriptionsWrapInsideTheirColumn() throws {
        let lines = HelpRenderer.render(width: 70, paint: false).components(separatedBy: "\n")
        let set = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("  eq set ") })
        let column = try XCTUnwrap(lines[set].range(of: "change")).lowerBound.utf16Offset(in: lines[set])
        let devices = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("  eq devices") })
        XCTAssertEqual(lines[devices + 1].prefix { $0 == " " }.count, column, lines[devices + 1])
        for line in lines where line.hasPrefix(" ") && !line.hasPrefix("  eq") {
            XCTAssertGreaterThanOrEqual(line.prefix { $0 == " " }.count, 4, "continuation back at the margin: \(line)")
        }
    }

    func testNarrowIsOneColumn() {
        let lines = HelpRenderer.render(width: 50, paint: false).components(separatedBy: "\n")
        let set = try! XCTUnwrap(lines.firstIndex { $0.hasPrefix("  eq set ") })
        XCTAssertTrue(lines[set + 1].hasPrefix("    "))
        XCTAssertFalse(lines[set].contains("change bands"))
    }

    func testDevicePlaceholderIsNamedDevice() {
        let plain = HelpRenderer.render(width: 120, paint: false)
        XCTAssertTrue(plain.contains("[--device DEVICE]"))
        XCTAssertFalse(plain.contains(" Q]"))
        XCTAssertFalse(plain.contains("--to Q"))
    }

    func testCommandHelpPrintsOnlyThatBlock() {
        let result = CLI.run(["set", "--help"], context: context)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("eq set [--device DEVICE]"), result.output)
        XCTAssertTrue(result.output.contains("eq set 64hz +4 1khz -3"))
        XCTAssertFalse(result.output.contains("preamp"))
        XCTAssertFalse(result.output.contains("look"))
        XCTAssertEqual(CLI.run(["help", "set"], context: context).output, result.output)
        let presets = CLI.run(["preset", "-h"], context: context).output
        XCTAssertTrue(presets.contains("eq preset rename"))
        XCTAssertFalse(presets.contains("eq set"))
    }

    func testFullHelpIsGrouped() {
        let output = CLI.run(["--help"], context: context).output
        for heading in ["look", "tune", "setup"] { XCTAssertTrue(output.contains("\n\(heading)\n") || output.hasPrefix("\(heading)\n"), heading) }
        XCTAssertEqual(CLI.run(["help"], context: context).output, output)
    }

    func testUnknownBandShowsOnlySetBlock() {
        _ = CLI.run(["init"], context: context)
        let result = CLI.run(["set", "99hz", "+1"], context: context)
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.hasPrefix("error: unknown band \"99hz\""), result.output)
        XCTAssertTrue(result.output.contains("\n\n  eq set [--device DEVICE]"), result.output)
        XCTAssertFalse(result.output.contains("eq preamp"))
        XCTAssertFalse(result.output.contains("tune"))
    }

    func testUnknownCommandShowsEverything() {
        let result = CLI.run(["frobnicate"], context: context)
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("eq preamp"))
        XCTAssertTrue(result.output.contains("eq doctor"))
    }

    func testCommandsOfEachBlock() {
        XCTAssertEqual(CommandHelp.entries(for: "on").count, 1)
        XCTAssertEqual(CommandHelp.entries(for: "off").count, 1)
        XCTAssertEqual(CommandHelp.entries(for: "import").count, 3)
        XCTAssertEqual(CommandHelp.entries(for: "show").count, 1)
        XCTAssertEqual(CommandHelp.tokens("[--device"), [.punctuation("["), .flag("--device")])
        XCTAssertEqual(CommandHelp.tokens("DEVICE]"), [.placeholder("DEVICE"), .punctuation("]")])
        XCTAssertEqual(CommandHelp.tokens("save|use"), [.word("save"), .punctuation("|"), .word("use")])
        XCTAssertEqual(CommandHelp.tokens("<file|url|name>"), [.placeholder("<file|url|name>")])
    }
}
