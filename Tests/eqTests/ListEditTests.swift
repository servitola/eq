import XCTest
@testable import eq

/// The Presets, Devices and Filters views edit through the watch session; each edit must leave
/// eq.json as its `eq` command does, and `u` must walk it back.
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
        let ctx = CLIContext(store: ConfigStore(url: dir.appendingPathComponent("eq.json")), statusURL: dir.appendingPathComponent("status.json"),
                             connectedDevices: { [("SPK", "Speakers", "builtin"), ("BT", "AirPods", "bluetooth")] },
                             defaultOutput: { ("SPK", "Speakers") },
                             setDefaultOutput: { outputs.set.append($0) },
                             fetch: { _ in throw URLError(.notConnectedToInternet) },
                             cacheDirectory: dir.appendingPathComponent("cache"), today: { "2026-09-30" })
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
        XCTAssertEqual(ctx.store.backups().count, backups + 1, "one backup for the session")
        for _ in 0..<5 { try session.apply(.undo) }
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
}
