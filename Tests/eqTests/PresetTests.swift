import XCTest
@testable import eq

final class PresetConfigTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let v4JSON = """
    {
      "default" : { "bands" : [4.8, 4, 4.2, 2.3, 0, -3.1, 0, 0, 3.1, 2.4], "preamp" : 0 },
      "devices" : {
        "BE" : { "bands" : [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], "name" : "BE-RCA", "preamp" : -2 }
      },
      "enabled" : true,
      "version" : 1
    }
    """

    func testV4ConfigLoadsWithoutPresetsAndSeedsOnce() throws {
        var config = try JSONDecoder().decode(Config.self, from: Data(v4JSON.utf8))
        XCTAssertNil(config.presets)
        XCTAssertNil(config.devices["BE"]?.preset)
        let before = config
        XCTAssertTrue(config.seedPresetsIfNeeded())
        XCTAssertEqual(config.presets?["favourite"], Profile(name: nil, preamp: 0, bands: Config.screenshotCurve))
        XCTAssertEqual(config.presets?["flat"], Profile.flat)
        XCTAssertEqual(config.presets?.count, 2)
        XCTAssertFalse(config.seedPresetsIfNeeded())
        config.presets = nil
        XCTAssertEqual(config, before, "seeding touches nothing but presets")
    }

    func testEmptyPresetsAreNotReseeded() {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.presets = [:]
        XCTAssertFalse(config.seedPresetsIfNeeded())
        XCTAssertEqual(config.presets, [:])
    }

    func testPresetAndProfilePresetRoundTrip() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("eq.json"))
        var config = Config.initial(builtInUID: "B", builtInName: "Built-in")
        config.devices["B"]?.preset = "favourite"
        try store.save(config)
        XCTAssertEqual(try store.load(), config)
        XCTAssertTrue(try String(contentsOf: store.url).contains("\"preset\" : \"favourite\""))
    }

    func testV4ProfileEncodesWithoutPresetKeys() throws {
        let store = ConfigStore(url: dir.appendingPathComponent("eq.json"))
        var config = try JSONDecoder().decode(Config.self, from: Data(v4JSON.utf8))
        config.presets = nil
        try store.save(config)
        let text = try String(contentsOf: store.url)
        XCTAssertFalse(text.contains("preset\""), text)
        XCTAssertFalse(text.contains("presets"), text)
    }

    func testLookupIsCaseInsensitiveAndKeepsStoredName() {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.presets = ["Favourite": Profile.flat]
        XCTAssertEqual(config.preset(named: "FAVOURITE")?.name, "Favourite")
        XCTAssertNil(config.preset(named: "nope"))
    }

    func testPresetNameRules() {
        XCTAssertTrue(Config.isValidPresetName("club mix-2_v.1"))
        XCTAssertTrue(Config.isValidPresetName(String(repeating: "a", count: 32)))
        XCTAssertFalse(Config.isValidPresetName(""))
        XCTAssertFalse(Config.isValidPresetName(String(repeating: "a", count: 33)))
        XCTAssertFalse(Config.isValidPresetName("a/b"))
        XCTAssertTrue(Config.isValidPresetName("Басы"))
    }

    func testPresetNameTrimming() {
        XCTAssertEqual(Config.normalizedPresetName(" fav "), "fav")
        XCTAssertTrue(Config.isValidPresetName(Config.normalizedPresetName(" fav ")))
        XCTAssertFalse(Config.isValidPresetName(Config.normalizedPresetName("   ")))
    }

    func testValidateRejectsBadPresets() {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.presets = ["bad/name": Profile.flat]
        XCTAssertThrowsError(try config.validate())
        config.presets = ["ok": Profile(name: nil, preamp: 0, bands: [1])]
        XCTAssertThrowsError(try config.validate()) { XCTAssertEqual($0 as? ConfigError, .bandCount("preset ok", 1)) }
        config.presets = ["Flat": Profile.flat, "flat": Profile.flat]
        XCTAssertThrowsError(try config.validate())
    }

    func testSameCurveIgnoresNameAndPreset() {
        let a = Profile(name: "A", preamp: 1, bands: Config.screenshotCurve, preset: "favourite")
        var b = Profile(name: nil, preamp: 1, bands: Config.screenshotCurve)
        XCTAssertTrue(a.sameCurve(as: b))
        b.preamp = 0
        XCTAssertFalse(a.sameCurve(as: b))
    }
}

final class BackupTests: XCTestCase {
    private var dir: URL!
    private var store: ConfigStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigStore(url: dir.appendingPathComponent("eq.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func config(preamp: Double) -> Config {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.default.preamp = preamp
        return config
    }

    func testElevenSavesKeepTenBackupsNewestFirst() throws {
        for i in 0...11 { try store.save(config(preamp: -Double(i))) }
        let backups = store.backups()
        XCTAssertEqual(backups.count, 10)
        XCTAssertEqual(backups.map(\.index), Array(1...10))
        XCTAssertEqual(try store.load(backup: 1).default.preamp, -10)
        XCTAssertEqual(try store.load(backup: 10).default.preamp, -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("eq.json.11").path))
    }

    func testTenFileCapHoldsAcrossUndoAndANewSave() throws {
        for i in 0...11 { try store.save(config(preamp: -Double(i))) }
        _ = try store.stepBack()
        _ = try store.stepBack()
        try store.save(config(preamp: -20))
        let backups = store.backups()
        XCTAssertEqual(backups.count, 10)
        XCTAssertEqual(backups.map(\.index), Array(1...10))
    }

    func testSaveWithoutBackupAndIdenticalSaveDoNotRotate() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1), backup: false)
        XCTAssertTrue(store.backups().isEmpty)
        try store.save(config(preamp: -1))
        XCTAssertTrue(store.backups().isEmpty, "an unchanged file is not a version worth undoing to")
    }

    func testStepBackWalksFurtherEachTimeAndStepForwardReturns() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1))
        try store.save(config(preamp: -2))
        try store.save(config(preamp: -3))
        XCTAssertEqual(try store.stepBack()?.index, 1)
        XCTAssertEqual(try store.load().default.preamp, -2, "the first undo goes back one save, not to the start")
        XCTAssertEqual(try store.stepBack()?.index, 2)
        XCTAssertEqual(try store.load().default.preamp, -1)
        XCTAssertEqual(try store.stepBack()?.index, 3)
        XCTAssertEqual(try store.load().default.preamp, 0)
        XCTAssertEqual(store.backups().map(\.index), [1, 2, 3], "undo never rearranges the backup chain")

        XCTAssertEqual(try store.stepForward()?.index, 2)
        XCTAssertEqual(try store.load().default.preamp, -1)
        XCTAssertEqual(try store.stepForward()?.index, 1)
        XCTAssertEqual(try store.load().default.preamp, -2)
        XCTAssertEqual(try store.stepForward()?.index, 0)
        XCTAssertEqual(try store.load().default.preamp, -3, "redoing all the way back reaches the latest edit")
        XCTAssertNil(try store.stepForward(), "nothing left once back at the latest edit")
    }

    func testStepBackReturnsNilPastTheOldestBackup() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1))
        XCTAssertNotNil(try store.stepBack())
        XCTAssertNil(try store.stepBack())
    }

    func testANewSaveAfterUndoingDropsTheRedoSide() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1))
        _ = try store.stepBack()
        XCTAssertEqual(store.historyPosition(), 1)
        try store.save(config(preamp: -9))
        XCTAssertEqual(store.historyPosition(), 0, "a real edit abandons the undo chain")
        XCTAssertNil(try store.stepForward())
    }

    func testStepBackRefusesInvalidBackupAndLeavesFilesAlone() throws {
        try store.save(config(preamp: 0))
        try "{ broken".write(to: dir.appendingPathComponent("eq.json.1"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.stepBack())
        XCTAssertEqual(try store.load().default.preamp, 0)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("eq.json.1")), "{ broken")
        XCTAssertEqual(store.historyPosition(), 0, "a refused step never moves the position")
    }

    private func toggled(_ enabled: Bool) -> Config {
        var config = config(preamp: 0)
        config.enabled = enabled
        return config
    }

    func testANoOpSaveAfterUndoKeepsRedo() throws {
        try store.save(toggled(false))
        try store.save(toggled(true))
        try store.save(toggled(false))
        XCTAssertEqual(try store.stepBack()?.index, 1)
        XCTAssertTrue(try store.load().enabled)
        try store.save(toggled(true))
        XCTAssertEqual(store.historyPosition(), 1, "an unchanged save is not an edit")
        XCTAssertEqual(try store.stepForward()?.index, 0)
        XCTAssertFalse(try store.load().enabled, "redo still reaches the latest version")
    }

    func testAnEditAfterUndoKeepsTheAbandonedLatestInHistory() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1))
        try store.save(config(preamp: -2))
        _ = try store.stepBack()
        try store.save(config(preamp: -9))
        XCTAssertEqual(store.historyPosition(), 0)
        XCTAssertEqual(try store.load(backup: 1).default.preamp, -1, "undo after the edit returns to what was edited")
        XCTAssertEqual(try store.load(backup: 2).default.preamp, -2, "the abandoned latest version stays in history")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.redoURL.path))
        XCTAssertEqual(try store.stepBack()?.index, 1)
        XCTAssertEqual(try store.load().default.preamp, -1)
    }

    func testABackgroundSaveAfterUndoKeepsRedo() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1))
        _ = try store.stepBack()
        var renamed = try store.load()
        renamed.default.name = "renamed by the daemon"
        try store.save(renamed, backup: false)
        XCTAssertEqual(store.historyPosition(), 1)
        XCTAssertEqual(try store.stepForward()?.index, 0)
        XCTAssertEqual(try store.load().default.preamp, -1)
        XCTAssertEqual(store.backups().count, 1, "nothing was pushed into the chain")
    }

    func testAHandEditMidUndoBecomesTheLatestVersion() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1))
        try store.save(config(preamp: -2))
        _ = try store.stepBack()
        var edited = try store.load()
        edited.default.preamp = -7
        try JSONEncoder().encode(edited).write(to: store.url)

        XCTAssertNotNil(try store.reconcileHistory())
        XCTAssertEqual(store.historyPosition(), 0)
        XCTAssertEqual(try store.load().default.preamp, -7, "the hand edit is never overwritten")
        XCTAssertEqual(try store.load(backup: 1).default.preamp, -1, "the version the edit started from")
        XCTAssertEqual(try store.load(backup: 2).default.preamp, -2, "the stashed latest version")
        XCTAssertNil(try store.stepForward())
    }

    func testStepBackAfterAHandEditMidUndoKeepsIt() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1))
        _ = try store.stepBack()
        var edited = try store.load()
        edited.default.preamp = -7
        try JSONEncoder().encode(edited).write(to: store.url)
        XCTAssertEqual(try store.stepBack()?.index, 1)
        XCTAssertEqual(try store.load().default.preamp, 0)
        XCTAssertEqual(try store.stepForward()?.index, 0)
        XCTAssertEqual(try store.load().default.preamp, -7, "redo reaches the hand edit")
        XCTAssertEqual(store.backups().map { try? store.load(backup: $0.index).default.preamp }, [0, -1, 0])
    }

    func testALegacyPositionWithoutDigestComparesAgainstTheBackup() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1))
        _ = try store.stepBack()
        try "1".write(to: store.positionURL, atomically: true, encoding: .utf8)
        XCTAssertNil(try store.reconcileHistory())
        XCTAssertEqual(try store.stepForward()?.index, 0)
        XCTAssertEqual(try store.load().default.preamp, -1)
    }

    func testAnOutOfRangePositionResetsToTheLatest() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1))
        _ = try store.stepBack()
        try "7".write(to: store.positionURL, atomically: true, encoding: .utf8)
        let note = try XCTUnwrap(try store.reconcileHistory())
        XCTAssertTrue(note.contains("not a saved version"), note)
        XCTAssertEqual(store.historyPosition(), 0)
        XCTAssertEqual(try store.load(backup: 1).default.preamp, -1, "the stashed latest is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.redoURL.path))
    }

    func testALeftoverStashAtPositionZeroIsKept() throws {
        try store.save(config(preamp: 0))
        try store.save(config(preamp: -1))
        _ = try store.stepBack()
        // A redo that stopped after clearing `.pos` but before writing `eq.json`.
        try FileManager.default.removeItem(at: store.positionURL)
        _ = try store.stepBack()
        XCTAssertEqual(store.backups().compactMap { try? store.load(backup: $0.index).default.preamp }, [-1, 0])
    }
}

final class PresetCLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-preset-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-27" })
        _ = run("init")
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private func json(_ args: String...) throws -> [String: Any] {
        let result = CLI.run(args + ["--json"], context: context)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any], result.output)
    }

    private var config: Config { get throws { try context.store.load() } }

    func testInitSeedsPresets() throws {
        XCTAssertEqual(try config.presets?.keys.sorted(), ["favourite", "flat"])
    }

    func testInitSeedsAnExistingConfigWithoutPresets() throws {
        var old = try config
        old.presets = nil
        try context.store.save(old, backup: false)
        run("init")
        XCTAssertEqual(try config.presets?.keys.sorted(), ["favourite", "flat"])
    }

    func testListMarksCurrentPreset() throws {
        run("preset", "use", "flat")
        let out = run("preset").output
        let lines = out.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("* flat") }, out)
        XCTAssertTrue(lines.contains { $0.hasPrefix("  favourite") }, out)
        let j = try json("preset")
        XCTAssertEqual(j["current"] as? String, "flat")
        XCTAssertEqual((j["presets"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["favourite", "flat"])
    }

    func testListWithoutCurrentPresetHasNullCurrent() throws {
        let j = try json("preset")
        XCTAssertTrue(j["current"] is NSNull)
    }

    func testSaveUseAndModifiedMarker() throws {
        run("set", "1khz", "+6")
        XCTAssertEqual(run("preset", "save", "Club").exitCode, 0)
        XCTAssertEqual(try config.presets?["Club"]?.bands[5], 6)
        XCTAssertEqual(try config.devices["BUILTIN"]?.preset, "Club")
        XCTAssertTrue(run().output.hasPrefix("MacBook Pro Speakers (own profile · Club)"), run().output)

        run("set", "1khz", "+5")
        XCTAssertEqual(try config.devices["BUILTIN"]?.preset, "Club", "an edit keeps the preset name")
        XCTAssertTrue(run().output.hasPrefix("MacBook Pro Speakers (own profile · Club*)"), run().output)
        XCTAssertTrue(run("preset").output.contains("* Club*"))

        let used = run("preset", "use", "club", "--device", "jbl")
        XCTAssertEqual(used.exitCode, 0, used.output)
        let jbl = try XCTUnwrap(try config.devices["BT-1"])
        XCTAssertEqual(jbl.bands[5], 6)
        XCTAssertEqual(jbl.name, "JBL Big")
        XCTAssertEqual(jbl.preset, "Club")
    }

    func testPreampAndImportClearKeepPreset() throws {
        run("preset", "use", "favourite")
        run("preamp", "-2")
        XCTAssertEqual(try config.devices["BUILTIN"]?.preset, "favourite")
        run("import", "--clear")
        XCTAssertEqual(try config.devices["BUILTIN"]?.preset, "favourite")
        XCTAssertTrue(run().output.hasPrefix("MacBook Pro Speakers (own profile · favourite)"), run().output)
    }

    func testProfileWithoutPresetKeepsTheOldHeader() {
        XCTAssertTrue(run().output.hasPrefix("MacBook Pro Speakers (own profile)   preamp"), run().output)
    }

    func testShowRenamesAndRemoves() throws {
        let shown = run("preset", "show", "FAVOURITE")
        XCTAssertEqual(shown.exitCode, 0)
        XCTAssertTrue(shown.output.contains("+4.8"))
        XCTAssertEqual(try json("preset", "show", "favourite")["preset"] as? String, "favourite")

        run("preset", "use", "favourite")
        XCTAssertEqual(run("preset", "rename", "favourite", "Mine").exitCode, 0)
        XCTAssertEqual(try config.presets?.keys.sorted(), ["Mine", "flat"])
        XCTAssertEqual(try config.devices["BUILTIN"]?.preset, "Mine")
        XCTAssertEqual(run("preset", "rename", "Mine", "FLAT").exitCode, 1)

        XCTAssertEqual(run("preset", "rm", "mine").exitCode, 0)
        XCTAssertEqual(try config.presets?.keys.sorted(), ["flat"])
        XCTAssertNil(try config.devices["BUILTIN"]?.preset)
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands, Config.screenshotCurve, "devices keep their curve")
    }

    func testSavePresetTrimsWhitespaceFromTheName() throws {
        XCTAssertEqual(run("preset", "save", " fav ").exitCode, 0)
        XCTAssertEqual(try config.presets?.keys.sorted(), ["fav", "favourite", "flat"])
        XCTAssertEqual(try config.devices["BUILTIN"]?.preset, "fav")
    }

    func testSavePresetRejectsAnAllWhitespaceName() throws {
        XCTAssertEqual(run("preset", "save", "   ").exitCode, 1)
        XCTAssertEqual(try json("preset", "save", "   ")["error"].flatMap { ($0 as? [String: Any])?["code"] as? String }, "badPresetName")
    }

    func testPresetErrors() throws {
        let missing = run("preset", "use", "nope")
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(missing.output.contains("no preset"), missing.output)
        XCTAssertEqual(try json("preset", "show", "nope")["error"].flatMap { ($0 as? [String: Any])?["code"] as? String }, "noSuchPreset")
        let bad = run("preset", "save", "a/b")
        XCTAssertEqual(bad.exitCode, 1)
        XCTAssertEqual(try json("preset", "save", "a/b")["error"].flatMap { ($0 as? [String: Any])?["code"] as? String }, "badPresetName")
        XCTAssertEqual(run("preset", "frobnicate").exitCode, 2)
    }

    func testPresetCommandsSeedAConfigThatHasNone() throws {
        var old = try config
        old.presets = nil
        try context.store.save(old, backup: false)
        XCTAssertTrue(run("preset").output.contains("favourite"))
        XCTAssertEqual(run("preset", "use", "flat").exitCode, 0)
        XCTAssertEqual(try config.presets?.keys.sorted(), ["favourite", "flat"])
    }

    func testUndoWalksBackFurtherEachTimeAndRedoWalksItAllBack() throws {
        run("set", "1khz", "+2")
        run("set", "1khz", "+4")
        run("set", "1khz", "+6")
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands[5], 6)

        let undone = run("undo")
        XCTAssertEqual(undone.exitCode, 0, undone.output)
        XCTAssertTrue(undone.output.contains("MacBook Pro Speakers"), undone.output)
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands[5], 4)
        XCTAssertEqual(run("undo").exitCode, 0)
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands[5], 2)
        XCTAssertEqual(run("undo").exitCode, 0)
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands[5], Config.screenshotCurve[5], "three undos reach the original curve")

        let redone = run("redo")
        XCTAssertEqual(redone.exitCode, 0, redone.output)
        XCTAssertTrue(redone.output.contains("MacBook Pro Speakers"), redone.output)
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands[5], 2)
        XCTAssertEqual(run("redo").exitCode, 0)
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands[5], 4)
        XCTAssertEqual(run("redo").exitCode, 0)
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands[5], 6, "three redos return to the latest edit")

        let noMore = run("redo")
        XCTAssertEqual(noMore.exitCode, 1)
        XCTAssertTrue(noMore.output.contains("nothing to redo"), noMore.output)
        XCTAssertEqual(try json("redo")["error"].flatMap { ($0 as? [String: Any])?["code"] as? String }, "noRedo")
    }

    func testANewSetAfterUndoingClearsRedo() throws {
        run("set", "1khz", "+6")
        XCTAssertEqual(run("undo").exitCode, 0)
        run("set", "1khz", "+9")
        let result = run("redo")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("nothing to redo"), result.output)
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands[5], 9, "the new edit stands, not the abandoned redo branch")
    }

    func testUndoAfterAHandEditMidUndoSaysSoAndKeepsIt() throws {
        run("set", "1khz", "+6")
        run("set", "1khz", "+9")
        XCTAssertEqual(run("undo").exitCode, 0)
        var edited = try config
        edited.devices["BUILTIN"]?.bands[5] = 1
        try JSONEncoder().encode(edited).write(to: context.store.url)
        let undone = run("undo")
        XCTAssertEqual(undone.exitCode, 0, undone.output)
        XCTAssertTrue(undone.output.contains("changed by hand"), undone.output)
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands[5], 6, "undo returns to the version the hand edit started from")
        XCTAssertEqual(run("redo").exitCode, 0)
        XCTAssertEqual(try config.devices["BUILTIN"]?.bands[5], 1, "redo reaches the hand edit")
    }

    func testHistoryRowsShowOffAndPreference() throws {
        run("off")
        run("on")
        run("bass", "3")
        let lines = run("history").output.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].contains("pref bass +3.0 dB"), "\(lines)")
        XCTAssertFalse(lines[0].contains("off"), "\(lines)")
        XCTAssertFalse(lines[1].contains("pref"), "\(lines)")
        XCTAssertTrue(lines[2].contains("  off"), "the version saved while off says so: \(lines)")
        let entries = try XCTUnwrap(try json("history")["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["enabled"] as? Bool }, [true, true, false, true])
    }

    func testUndoWithoutBackup() throws {
        let result = run("undo")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("nothing to undo"), result.output)
        XCTAssertEqual(try json("undo")["error"].flatMap { ($0 as? [String: Any])?["code"] as? String }, "noBackup")
    }

    func testUndoWithUnreadableBackupGivesAClearError() throws {
        run("set", "1khz", "+6")
        try "{ broken".write(to: dir.appendingPathComponent("eq.json.1"), atomically: true, encoding: .utf8)
        let result = run("undo")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("backup eq.json.1 is unreadable — see eq history"), result.output)
        XCTAssertEqual(try json("undo")["error"].flatMap { ($0 as? [String: Any])?["code"] as? String }, "unreadableBackup")
    }

    func testHistoryListsEveryVersionAndMarksThePosition() throws {
        run("set", "1khz", "+6")
        run("set", "1khz", "+9")
        let out = run("history").output
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, out)
        XCTAssertTrue(lines[0].hasPrefix("  0  "), out)
        XCTAssertTrue(lines[0].contains("+9.0"), out)
        XCTAssertTrue(lines[0].hasSuffix("←") || lines[0].contains("\u{2190}"), "the current position is marked: \(out)")
        XCTAssertFalse(lines[1].contains("\u{2190}") || lines[2].contains("\u{2190}"))
        XCTAssertTrue(lines[1].hasPrefix("  1  "), out)
        XCTAssertTrue(lines[1].contains("+6.0"), out)
        XCTAssertTrue(lines[2].contains("-3.1"), "the oldest row is the config before either set: \(out)")

        XCTAssertEqual(run("undo").exitCode, 0)
        let afterUndo = run("history").output.components(separatedBy: "\n")
        XCTAssertTrue(afterUndo[1].contains("\u{2190}"), "undo moves the marker to position 1: \(afterUndo)")

        let j = try json("history")
        XCTAssertEqual(j["position"] as? Int, 1)
        XCTAssertEqual((j["entries"] as? [[String: Any]])?.count, 3)

        // eq undo --list is kept as an alias for eq history.
        XCTAssertEqual(run("undo", "--list").output, run("history").output)
    }
}
