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

    func testNoneTurnsTheCompressorOffInAnyCase() throws {
        for word in ["none", "NONE", "None", "Off"] {
            run("comp", "gentle")
            XCTAssertEqual(run("comp", word).exitCode, 0, word)
            XCTAssertNil(try layer(), word)
        }
        run("comp", "gentle")
        XCTAssertEqual(run("comp", "NONE", "--dry-run").exitCode, 0)
        XCTAssertEqual(try layer()?.comp, .gentle)
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

        var config = try context.store.load()
        config.default.dynamics = Dynamics(color: .init(kind: .tape, amount: 2))
        XCTAssertThrowsError(try config.validate()) {
            XCTAssertEqual($0 as? ConfigError, .preferenceOutOfRange("default", "color amount 2.0 (0…1)"))
        }
    }

    /// A mode or kind this build does not know, from a newer eq or a typo, costs only itself: the
    /// file still loads, the unknown part runs nothing and survives a save, and setting it repairs it.
    func testAnUnknownModeOrKindIsKeptAndIgnored() throws {
        var text = try String(contentsOf: context.store.url, encoding: .utf8)
        let builtin = try XCTUnwrap(text.range(of: #""BUILTIN" : {"#))
        text.replaceSubrange(builtin, with: #""BUILTIN" : {"dynamics": {"comp": "loud", "color": {"kind": "fuzz", "amount": 0.4}},"#)
        try text.write(to: context.store.url, atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(try layer())
        XCTAssertNil(loaded.comp)
        XCTAssertNil(loaded.color)
        XCTAssertEqual(loaded.unknown, [#"comp mode "loud""#, #"color "fuzz""#])
        XCTAssertFalse(DynamicsCoefficients.make(loaded, sampleRate: 48000).isActive)
        XCTAssertTrue(run().output.contains(#"dynamics: comp loud (unknown)  color fuzz 0.4 (unknown)"#), run().output)

        XCTAssertEqual(run("bass", "2").exitCode, 0)
        XCTAssertEqual(try layer()?.unknown, [#"comp mode "loud""#, #"color "fuzz""#], "a save keeps what it does not know")
        let saved = try String(contentsOf: context.store.url, encoding: .utf8)
        XCTAssertTrue(saved.contains(#""comp" : "loud""#) && saved.contains(#""kind" : "fuzz""#), saved)
        XCTAssertEqual(run("export").exitCode, 0)
        XCTAssertEqual(warnings, [], "nothing that runs is left out")

        XCTAssertEqual(run("comp", "off").exitCode, 0)
        XCTAssertEqual(try layer()?.unknown, [#"color "fuzz""#])
        XCTAssertEqual(run("color", "tape", "0.3").exitCode, 0)
        XCTAssertEqual(try layer(), Dynamics(color: .init(kind: .tape, amount: 0.3)))
    }

    func testDoctorWarnsAboutAnUnknownModeOrKind() throws {
        var config = try context.store.load()
        config.default.dynamics = try JSONDecoder().decode(Dynamics.self, from: Data(#"{"comp": "loud"}"#.utf8))
        config.presets?["movie"] = Profile(name: nil, preamp: 0, bands: Profile.flat.bands,
                                           dynamics: try JSONDecoder().decode(Dynamics.self, from: Data(#"{"color": {"kind": "fuzz", "amount": 1}}"#.utf8)))
        XCTAssertEqual(Doctor.configCheck(config, fileExists: true),
                       DoctorCheck(name: "config", ok: false,
                                   detail: #"default: no comp mode "loud" — ignored; preset movie: no color "fuzz" — ignored"#, warning: true))
        config.default.dynamics = nil
        config.presets?["movie"] = nil
        XCTAssertEqual(Doctor.configCheck(config, fileExists: true), DoctorCheck(name: "config", ok: true, detail: "ok", warning: false))
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
        XCTAssertTrue(zsh.contains("(comp) subs=(gentle night off none)"), zsh)
        XCTAssertTrue(zsh.contains("(color) subs=(tape tube off)"), zsh)
        XCTAssertTrue(zsh.contains("('color tape') flags=(--device --dry-run); operands=(none)"), zsh)
        XCTAssertTrue(ManPage.render(version: "dev").contains("eq comp gentle|night|off|none"))
        XCTAssertTrue(run("comp", "--help").output.contains("night is 4:1"))
        XCTAssertEqual(CommandHelp.form(matching: ["color", "tube", "0.5"])?.writes, true)
    }
}

final class DynamicsWatchTests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-dynwatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-28" })
        _ = CLI.run(["init"], context: context)
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func layer() throws -> Dynamics? {
        try context.store.load().devices["BUILTIN"]?.dynamics
    }

    func testKeysOnBothLayouts() {
        for key in ["c", "C", "с", "С"] { XCTAssertEqual(WatchKeys.action(for: key), .cycleComp, key) }
        for key in ["v", "м"] { XCTAssertEqual(WatchKeys.action(for: key), .cycleColour, key) }
        for key in ["V", "М"] { XCTAssertEqual(WatchKeys.action(for: key), .colourAmount, key) }
    }

    func testSessionCyclesModesAndAmount() throws {
        let session = CLI.WatchSession(context)
        XCTAssertThrowsError(try session.apply(.colourAmount))
        try session.apply(.cycleComp)
        XCTAssertEqual(try layer()?.comp, .gentle)
        try session.apply(.cycleComp)
        XCTAssertEqual(try layer()?.comp, .night)
        try session.apply(.cycleComp)
        XCTAssertNil(try layer())

        try session.apply(.cycleColour)
        XCTAssertEqual(try layer()?.color, .init(kind: .tape, amount: 0.3))
        try session.apply(.colourAmount)
        XCTAssertEqual(try layer()?.color, .init(kind: .tape, amount: 0.4))
        try session.apply(.cycleColour)
        XCTAssertEqual(try layer()?.color, .init(kind: .tube, amount: 0.4))
        for _ in 0..<6 { try session.apply(.colourAmount) }
        XCTAssertEqual(try layer()?.color?.amount, 1)
        try session.apply(.colourAmount)
        XCTAssertEqual(try layer()?.color?.amount, 0.1)
        XCTAssertEqual(session.header().dynamics, Dynamics(color: .init(kind: .tube, amount: 0.1)))
        try session.apply(.cycleColour)
        XCTAssertNil(try layer())

        for _ in 0..<14 { try session.apply(.undo) }
        XCTAssertNil(try layer())
        XCTAssertThrowsError(try session.apply(.undo))
    }

    func testHeaderShowsTheLiveReductionAndTheColour() {
        var f = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: [], out: [], peak: -6, limiting: false,
                           gains: [], preamp: 0, enabled: true, comp: -3.24)
        let layout = WatchLayout.fit(cols: 140, rows: 30)
        let dynamics = Dynamics(comp: .night, color: .init(kind: .tape, amount: 0.3))
        XCTAssertTrue(Watch.frame(f, layout: layout, dynamics: dynamics)[0].contains("preamp +0.0 dB · night comp -3.2 · tape 0.3 · peak"))
        f.comp = nil
        XCTAssertTrue(Watch.frame(f, layout: layout, dynamics: dynamics)[0].contains("· night comp · tape 0.3 ·"))
        XCTAssertFalse(Watch.frame(f, layout: layout)[0].contains("comp"))
    }

    func testHintNamesTheKeys() {
        XCTAssertTrue(HintBox.rows.contains { $0.contains("comp/color, ⇧v amt") })
        XCTAssertTrue(HintBox.compact(width: 400).contains("c comp · v color"))
    }

    func testFrameAndStatusCarryTheReductionOnlyWhileItRuns() throws {
        let off = MeterFrame(t: 0, device: nil, rate: 48000, in: [], out: [], peak: 0, limiting: false, gains: [], preamp: 0, enabled: true)
        XCTAssertFalse(String(decoding: try MeterFrame.encodeLine(off), as: UTF8.self).contains("comp"))
        var on = off
        on.comp = -2.5
        let line = try MeterFrame.encodeLine(on)
        XCTAssertTrue(String(decoding: line, as: UTF8.self).contains(#""comp":-2.5"#))
        XCTAssertEqual(try JSONDecoder().decode(MeterFrame.self, from: line), on)

        var status = Status(state: .running, device: .init(uid: "BUILTIN", name: "MacBook Pro Speakers", transport: "builtin"),
                            sampleRate: 48000, profile: .device, framesProcessed: 1, callbacks: 1, writes: 1, enabled: true,
                            error: nil, pid: getpid(), version: "dev", updatedAt: Date())
        status.compReductionDB = -3.2
        try status.write(to: context.statusURL)
        XCTAssertEqual(Status.read(from: context.statusURL)?.compReductionDB, -3.2)
        let text = CLI.run(["status"], context: context).output
        XCTAssertTrue(text.contains("comp: -3.2 dB"), text)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(CLI.run(["status", "--json"], context: context).output.utf8)) as? [String: Any])
        XCTAssertEqual(json["compReductionDB"] as? Double, -3.2)

        status.compReductionDB = -0.0
        try status.write(to: context.statusURL)
        let zero = CLI.run(["status"], context: context).output
        XCTAssertTrue(zero.contains("comp: 0.0 dB"), zero)
    }
}
