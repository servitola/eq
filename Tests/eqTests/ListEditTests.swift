import XCTest
@testable import eq

/// The Presets, Devices, Filters, Apps and History views edit through the watch session; each edit
/// must leave eq.json as its `eq` command does, and `u` must walk it back.
final class ListEditTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private final class Outputs {
        var set: [String] = []
    }

    private static let filters = [Filter(type: .lowShelf, frequency: 105, gain: 4, q: 0.7, origin: .import),
                                  Filter(type: .peak, frequency: 3000, gain: -2, q: 1.41, origin: .hand)]

    private func context(_ outputs: Outputs = Outputs()) throws -> CLIContext {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-lists-\(UUID().uuidString)")
        var ctx = CLIContext(store: ConfigStore(url: dir.appendingPathComponent("eq.json")), statusURL: dir.appendingPathComponent("status.json"),
                             connectedDevices: { [("SPK", "Speakers", "builtin"), ("BT", "AirPods", "bluetooth")] },
                             defaultOutput: { ("SPK", "Speakers") },
                             setDefaultOutput: { outputs.set.append($0) },
                             fetch: { _ in throw URLError(.notConnectedToInternet) },
                             cacheDirectory: dir.appendingPathComponent("cache"), today: { "2026-09-30" })
        ctx.audioApps = { [PlayingApp(id: "com.spotify.client", name: "Spotify"), PlayingApp(id: "com.apple.Music", name: "Music")] }
        var config = try ctx.store.loadOrCreate(builtInUID: "SPK", builtInName: "Speakers")
        config.presets?["night"] = Profile(name: nil, preamp: -2, bands: [3, 2, 1, 0, 0, 0, 0, -1, -2, -3], dynamics: Dynamics(comp: .night))
        config.devices["SPK"]?.filters = Self.filters
        config.devices["SPK"]?.imported = "AutoEq · HD 600"
        config.devices["SPK"]?.preset = "night"
        config.apps = [AppRule(app: "com.spotify.client", preset: "night")]
        try ctx.store.save(config)
        return ctx
    }

    func testEachListEditSavesWhatItsCommandSaves() throws {
        let cases: [([String], WatchAction)] = [
            (["preset", "use", "night"], .usePreset("night")),
            (["preset", "use", "FLAT"], .usePreset("FLAT")),
            (["preset", "save", "club mix"], .savePreset("club mix")),
            (["preset", "rename", "night", "late"], .renamePreset("night", "late")),
            (["preset", "rm", "night"], .removePreset("night")),
            (["device", "copy", "--to", "AirPods"], .copyCurve(DeviceChoice(uid: "BT", name: "AirPods"))),
            (["filter", "add", "peak", "250", "-3.5", "2"], .addFilter(Filter(type: .peak, frequency: 250, gain: -3.5, q: 2, origin: .hand))),
            (["filter", "set", "1", "gain=2", "q=0.5", "type=highshelf", "freq=8k"],
             .setFilter(0, Filter(type: .highShelf, frequency: 8000, gain: 2, q: 0.5, origin: .hand))),
            (["filter", "rm", "1"], .removeFilter(0)),
            (["filter", "rm", "2"], .removeFilter(1)),
            (["app", "set", "Music", "flat"], .setAppRule("Music", "flat")),
            (["app", "set", "com.spotify.client", "FLAT"], .setAppRule("com.spotify.client", "FLAT")),
            (["app", "rm", "Spotify"], .removeAppRule("Spotify")),
            (["app", "on"], .followApps(true)),
            (["app", "off"], .followApps(false)),
        ]
        for (args, action) in cases {
            let cli = try context(), tui = try context()
            let result = CLI.run(args, context: cli)
            XCTAssertEqual(result.exitCode, 0, "\(args): \(result.output)")
            try CLI.WatchSession(tui).apply(action)
            XCTAssertEqual(try tui.store.load(), try cli.store.load(), "\(action) against eq \(args.joined(separator: " "))")
        }
    }

    func testRefusalsAreTheCommandsOwn() throws {
        let ctx = try context()
        let session = CLI.WatchSession(ctx)
        XCTAssertThrowsError(try session.apply(.renamePreset("night", "Flat"))) { XCTAssertEqual($0 as? CLIError, .presetExists("flat")) }
        XCTAssertThrowsError(try session.apply(.renamePreset("night", "a/b"))) { XCTAssertEqual($0 as? CLIError, .badPresetName("a/b")) }
        XCTAssertThrowsError(try session.apply(.removePreset("gone"))) { XCTAssertEqual($0 as? CLIError, .noSuchPreset("gone")) }
        XCTAssertThrowsError(try session.apply(.removeFilter(5))) { XCTAssertEqual($0 as? CLIError, .noSuchFilter("6", 2)) }
        XCTAssertThrowsError(try session.apply(.setAppRule("Music", "gone"))) { XCTAssertEqual($0 as? CLIError, .noSuchPreset("gone")) }
        XCTAssertThrowsError(try session.apply(.removeAppRule("com.apple.Music"))) { XCTAssertEqual($0 as? CLIError, .noSuchAppRule("com.apple.Music")) }
        XCTAssertThrowsError(try session.apply(.setFilter(0, Filter(type: .peak, frequency: 40000, gain: 0, q: 1)))) {
            XCTAssertTrue("\($0)".contains("outside the allowed range"), "\($0)")
        }
        XCTAssertEqual(try ctx.store.load().devices["SPK"]?.filters, Self.filters, "a refused edit writes nothing")
    }

    func testDeviceUseMovesTheOutputAndSavesNothing() throws {
        let outputs = Outputs()
        let ctx = try context(outputs)
        let before = try ctx.store.load()
        let session = CLI.WatchSession(ctx)
        try session.apply(.useDevice("BT"))
        XCTAssertEqual(outputs.set, ["BT"])
        XCTAssertEqual(try ctx.store.load(), before)
        XCTAssertThrowsError(try session.apply(.undo), "moving the output is not a curve change")
        XCTAssertThrowsError(try session.apply(.useDevice("gone"))) { XCTAssertEqual($0 as? CLIError, .noSuchDevice("gone")) }
    }

    func testUWalksBackPresetsRulesAndOtherDevices() throws {
        let ctx = try context()
        let start = try ctx.store.load()
        let backups = ctx.store.backups().count
        let session = CLI.WatchSession(ctx)
        try session.apply(.renamePreset("night", "late"))
        XCTAssertEqual(try ctx.store.load().apps, [AppRule(app: "com.spotify.client", preset: "late")], "rules follow a rename")
        try session.apply(.copyCurve(DeviceChoice(uid: "BT", name: "AirPods")))
        try session.apply(.removePreset("late"))
        try session.apply(.addFilter(Filter(type: .notch, frequency: 60, gain: 0, q: 10, origin: .hand)))
        try session.apply(.savePreset("mine"))
        try session.apply(.followApps(true))
        try session.apply(.setAppRule("Music", "mine"))
        XCTAssertEqual(ctx.store.backups().count, backups + 1, "one backup for the session")
        for _ in 0..<7 { try session.apply(.undo) }
        XCTAssertEqual(try ctx.store.load(), start, "presets, rules and AirPods' own profile are back")
        XCTAssertThrowsError(try session.apply(.undo))
    }

    func testTuneCanEditADeviceThatIsNotPlaying() throws {
        let ctx = try context()
        let session = CLI.WatchSession(ctx)
        session.device = DeviceChoice(uid: "BT", name: "AirPods")
        try session.apply(.adjust(.band(0), 0.5))
        let config = try ctx.store.load()
        XCTAssertEqual(config.devices["BT"]?.bands[0], config.default.bands[0] + 0.5)
        XCTAssertEqual(config.devices["BT"]?.name, "AirPods")
        XCTAssertEqual(config.devices["SPK"]?.bands, Config.screenshotCurve, "the playing device is left alone")
        XCTAssertEqual(session.header().profile?.bands, Config.screenshotCurve, "the header is still the playing device's")
        let cli = try context()
        _ = CLI.run(["set", "--device", "AirPods", "32hz", String(config.default.bands[0] + 0.5)], context: cli)
        XCTAssertEqual(try cli.store.load().devices, config.devices, "as eq set --device does")
        session.device = nil
        try session.apply(.undo)
        XCTAssertNil(try ctx.store.load().devices["BT"])
    }

    /// Restoring version n is `eq undo` (or `eq redo`) as many times as it takes: the same file, the
    /// same place in the chain, the same stash for redo.
    func testRestoringAVersionIsUndoOrRedoRepeated() throws {
        let cli = try context(), tui = try context()
        for ctx in [cli, tui] {
            for gain in ["+1", "+2", "+3"] { XCTAssertEqual(CLI.run(["set", "64hz", gain], context: ctx).exitCode, 0) }
        }
        func state(_ ctx: CLIContext) throws -> (Config, Int, Data?) {
            (try ctx.store.load(), ctx.store.historyPosition(), try? Data(contentsOf: ctx.store.redoURL))
        }
        for _ in 0..<2 { XCTAssertEqual(CLI.run(["undo"], context: cli).exitCode, 0) }
        let session = CLI.WatchSession(tui)
        try session.apply(.restoreVersion(2))
        var (a, b) = (try state(cli), try state(tui))
        XCTAssertEqual(a.0, b.0)
        XCTAssertEqual(a.1, 2)
        XCTAssertEqual(b.1, 2)
        XCTAssertEqual(a.2, b.2)
        XCTAssertEqual(try tui.store.load().devices["SPK"]?.bands[1], try CLI.historyVersions(tui).versions[2].profile?.bands[1])
        XCTAssertThrowsError(try session.apply(.undo), "the session's own steps start over from the version restored")
        XCTAssertEqual(CLI.run(["redo"], context: cli).exitCode, 0)
        try session.apply(.restoreVersion(1))
        (a, b) = (try state(cli), try state(tui))
        XCTAssertEqual(a.0, b.0)
        XCTAssertEqual(a.1, b.1)
        XCTAssertThrowsError(try session.apply(.restoreVersion(9))) { XCTAssertEqual($0 as? CLIError, .noBackup) }
        XCTAssertEqual(tui.store.historyPosition(), 1, "a version that is not there moves nothing")
        try session.apply(.restoreVersion(0))
        XCTAssertEqual(tui.store.historyPosition(), 0)
        XCTAssertEqual(try tui.store.load().devices["SPK"]?.bands[1], 3)
        try session.apply(.adjust(.band(0), 0.5))
        try session.apply(.undo)
        XCTAssertEqual(try tui.store.load().devices["SPK"]?.bands[1], 3, "an edit after a restore is a step of its own")
    }
}
