import XCTest
@testable import eq

final class DynamicsCLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!
    private var warnings: [String] = []

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-dyn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-28" })
        context.warn = { [unowned self] in self.warnings.append($0) }
        _ = CLI.run(["init"], context: context)
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private func layer(_ uid: String = "BUILTIN") throws -> Dynamics? {
        try XCTUnwrap(try context.store.load().devices[uid]).dynamics
    }

    func testCommandsSetAndClearTheLayer() throws {
        XCTAssertEqual(run("comp", "gentle").output.components(separatedBy: "\n").first, "comp gentle")
        XCTAssertEqual(run("color", "tape", "0,3").exitCode, 0)
        XCTAssertEqual(try layer(), Dynamics(comp: .gentle, color: .init(kind: .tape, amount: 0.3)))
        XCTAssertTrue(run().output.contains("dynamics: comp gentle  color tape 0.3"), run().output)
        run("comp", "NIGHT")
        XCTAssertEqual(try layer()?.comp, .night)
        run("comp", "off")
        XCTAssertEqual(try layer(), Dynamics(color: .init(kind: .tape, amount: 0.3)))
        run("color", "tube", "0")
        XCTAssertNil(try layer())
        XCTAssertFalse(run().output.contains("dynamics"))
        run("color", "tube", "1")
        run("color", "off")
        XCTAssertNil(try layer())
    }

    func testBadInputIsAUsageError() throws {
        for args in [["comp"], ["comp", "loud"], ["comp", "gentle", "night"], ["color", "tape"], ["color", "warm", "0.3"],
                     ["color", "tape", "1.5"], ["color", "tube", "-0.1"], ["color", "tape", "much"], ["color"]] {
            XCTAssertEqual(CLI.run(args, context: context).exitCode, 2, "\(args)")
        }
        XCTAssertNil(try layer())
    }

    func testDeviceOptionAndJSON() throws {
        let result = CLI.run(["comp", "night", "--device", "jbl", "--json"], context: context)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any], result.output)
        let dynamics = try XCTUnwrap((json["profile"] as? [String: Any])?["dynamics"] as? [String: Any])
        XCTAssertEqual(dynamics["comp"] as? String, "night")
        XCTAssertEqual(try layer("BT-1")?.comp, .night)
        XCTAssertNil(try layer())
    }

    func testStoredShapeAndHandEdits() throws {
        run("comp", "gentle")
        run("color", "tape", "0.3")
        let text = try String(contentsOf: context.store.url, encoding: .utf8)
        XCTAssertTrue(text.contains(#""dynamics" : {"#), text)
        let profile = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let stored = ((profile["devices"] as? [String: Any])?["BUILTIN"] as? [String: Any])?["dynamics"] as? [String: Any]
        XCTAssertEqual(stored?["comp"] as? String, "gentle")
        XCTAssertEqual((stored?["color"] as? [String: Any])?["kind"] as? String, "tape")
        XCTAssertEqual((stored?["color"] as? [String: Any])?["amount"] as? Double, 0.3)

        let off = #"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0],"dynamics":{"color":{"kind":"tube","amount":0}}}"#
        XCTAssertNil(try JSONDecoder().decode(Profile.self, from: Data(off.utf8)).dynamics)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(Profile.flat), as: UTF8.self).contains("dynamics"))
        let unknown = #"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0],"dynamics":{"comp":"loud"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Profile.self, from: Data(unknown.utf8)))

        var config = try context.store.load()
        config.default.dynamics = Dynamics(color: .init(kind: .tape, amount: 2))
        XCTAssertThrowsError(try config.validate()) {
            XCTAssertEqual($0 as? ConfigError, .preferenceOutOfRange("default", "color amount 2.0 (0…1)"))
        }
    }

    func testPresetsCarryItFlatDropsItAndItCountsAsAChange() throws {
        run("comp", "night")
        XCTAssertEqual(run("preset", "save", "movie").exitCode, 0)
        XCTAssertEqual(try context.store.load().presets?["movie"]?.dynamics, Dynamics(comp: .night))
        run("flat")
        XCTAssertNil(try layer())
        run("preset", "use", "movie")
        XCTAssertEqual(try layer(), Dynamics(comp: .night))
        XCTAssertFalse(run().output.contains("movie*"))
        run("comp", "gentle")
        XCTAssertTrue(run().output.contains("movie*"))
    }

    func testUndoAndHistorySeeIt() throws {
        run("comp", "gentle")
        run("color", "tube", "0.5")
        XCTAssertTrue(run("history").output.contains("comp gentle  color tube 0.5"), run("history").output)
        run("undo")
        XCTAssertEqual(try layer(), Dynamics(comp: .gentle))
        run("undo")
        XCTAssertNil(try layer())
    }

    func testDryRunShowsTheChangeAndWritesNothing() throws {
        let before = try Data(contentsOf: context.store.url)
        let result = run("comp", "night", "--dry-run")
        XCTAssertEqual(result.exitCode, 0, result.output)
        let after = try XCTUnwrap(result.output.components(separatedBy: "\nafter\n").last)
        XCTAssertTrue(after.contains("dynamics: comp night"), result.output)
        XCTAssertEqual(try Data(contentsOf: context.store.url), before)
    }

    func testExportWarnsForOtherToolsAndOwnJSONRoundTrips() throws {
        run("comp", "gentle")
        run("color", "tape", "0.3")
        let apo = run("export")
        XCTAssertEqual(apo.exitCode, 0)
        XCTAssertFalse(apo.output.contains("comp"))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("exported the EQ without comp gentle and color tape"), warnings[0])

        let file = dir.appendingPathComponent("own.json")
        warnings = []
        XCTAssertEqual(run("export", "--format", "json", "--out", file.path).exitCode, 0)
        XCTAssertEqual(warnings, [])
        run("comp", "off")
        run("color", "off")
        XCTAssertEqual(run("import", file.path).exitCode, 0)
        XCTAssertEqual(try layer(), Dynamics(comp: .gentle, color: .init(kind: .tape, amount: 0.3)))

        run("flat")
        let flat = dir.appendingPathComponent("flat.json")
        run("export", "--format", "json", "--out", flat.path)
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: Data(contentsOf: flat)) as? [String: Any])?["dynamics"])
        run("comp", "night")
        run("import", flat.path)
        XCTAssertNil(try layer(), "re-importing a flat export clears the layer set since")

        run("comp", "night")
        let older = dir.appendingPathComponent("older.json")
        try Data(#"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0],"dynamics":{"comp":"loud","color":{"kind":"tube","amount":3}}}"#.utf8).write(to: older)
        let imported = run("import", older.path)
        XCTAssertTrue(imported.output.contains("dynamics comp: skipped"), imported.output)
        XCTAssertTrue(imported.output.contains("dynamics color: skipped"), imported.output)
        XCTAssertNil(try layer())
    }

    func testHelpCompletionsAndManPageComeFromTheTable() {
        let zsh = Completions.script(.zsh)
        XCTAssertTrue(zsh.contains("(comp) subs=(gentle night off)"), zsh)
        XCTAssertTrue(zsh.contains("(color) subs=(tape tube off)"), zsh)
        XCTAssertTrue(zsh.contains("('color tape') flags=(--device --dry-run); operands=(none)"), zsh)
        XCTAssertTrue(ManPage.render(version: "dev").contains("eq comp gentle|night|off"))
        XCTAssertTrue(run("comp", "--help").output.contains("night is 4:1"))
        XCTAssertEqual(CommandHelp.form(matching: ["color", "tube", "0.5"])?.writes, true)
    }
}
