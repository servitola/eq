import XCTest
@testable import eq

final class AppCLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!
    private let spotify = AppMatch(app: "com.spotify.client", name: "Spotify", preset: "favourite")

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-28" })
        context.audioApps = { [PlayingApp(id: "com.spotify.client", name: "Spotify"), PlayingApp(id: "com.google.Chrome", name: "Google Chrome")] }
        context.findApp = { $0.lowercased() == "music" ? PlayingApp(id: "com.apple.Music", name: "Music") : nil }
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

    private func rules() throws -> [AppRule] { try context.store.load().apps ?? [] }

    private func writeStatus(_ apps: AppsStatus?) throws {
        try Status(state: .running, device: .init(uid: "BUILTIN", name: "MacBook Pro Speakers", transport: "builtin"), sampleRate: 48000,
                   profile: .device, framesProcessed: 1, callbacks: 1, writes: 1, enabled: true, error: nil, pid: getpid(),
                   version: Build.version, updatedAt: Date(), apps: apps)
            .write(to: context.statusURL)
    }

    func testSetResolvesARunningNameAnInstalledNameOrABundleIDAndKeepsOrder() throws {
        run("init")
        XCTAssertEqual(run("app", "set", "spotify", "Favourite").exitCode, 0)
        XCTAssertEqual(run("app", "set", "Music", "flat").exitCode, 0)
        XCTAssertEqual(run("app", "set", "org.videolan.vlc", "flat").exitCode, 0)
        XCTAssertEqual(try rules(), [AppRule(app: "com.spotify.client", preset: "favourite"), AppRule(app: "com.apple.Music", preset: "flat"),
                                     AppRule(app: "org.videolan.vlc", preset: "flat")])
        run("app", "set", "com.spotify.client", "flat")
        XCTAssertEqual(try rules().first, AppRule(app: "com.spotify.client", preset: "flat"), "a second rule for an app replaces the first in place")
        XCTAssertEqual(try rules().count, 3)
    }

    func testSetRefusesAnUnknownAppOrPreset() throws {
        run("init")
        let app = run("app", "set", "Nonesuch", "flat")
        XCTAssertEqual(app.exitCode, 1)
        XCTAssertTrue(app.output.contains("no app \"Nonesuch\""), app.output)
        XCTAssertEqual(try json("app", "set", "Nonesuch", "flat")["error"].flatMap { ($0 as? [String: Any])?["code"] as? String }, "noSuchApp")
        XCTAssertEqual(run("app", "set", "Spotify", "nope").exitCode, 1)
        XCTAssertEqual(try rules(), [])
        XCTAssertEqual(run("app", "set", "Spotify").exitCode, 2)
    }

    func testSetSaysTheFeatureIsOffAndOnOffTogglesOnlyTheFlag() throws {
        run("init")
        XCTAssertTrue(run("app", "set", "Spotify", "favourite").output.contains("apps are off — eq app on"))
        XCTAssertFalse(try context.store.load().followsApps)
        run("app", "on")
        XCTAssertTrue(try context.store.load().followsApps)
        XCTAssertFalse(run("app", "set", "Spotify", "flat").output.contains("apps are off"))
        run("app", "off")
        let config = try context.store.load()
        XCTAssertNil(config.experimental)
        XCTAssertEqual(config.apps?.count, 1)
    }

    func testListMarksTheAppHeardNowAndARuleWithoutItsPreset() throws {
        run("init")
        XCTAssertTrue(run("app").output.contains("no rules"))
        run("app", "set", "Spotify", "favourite")
        run("app", "set", "Google Chrome", "flat")
        run("app", "on")
        run("preset", "rm", "flat")
        try writeStatus(AppsStatus(listening: true, overlay: spotify, held: nil, lastMatch: spotify, lastMatchAt: Date()))
        let list = run("app", "list")
        XCTAssertEqual(run("app").output, list.output)
        XCTAssertTrue(list.output.contains("* Spotify (com.spotify.client) → favourite"), list.output)
        XCTAssertTrue(list.output.contains("  Google Chrome (com.google.Chrome) → flat (no such preset)"), list.output)
        XCTAssertTrue(list.output.contains("app: Spotify → favourite"), list.output)
        let report = try json("app")
        XCTAssertEqual(report["on"] as? Bool, true)
        XCTAssertEqual((report["heard"] as? [String: String])?["preset"], "favourite")
        XCTAssertEqual((report["rules"] as? [[String: Any]])?.last?["missing"] as? Bool, true)
    }

    func testRmTakesANameOrABundleID() throws {
        run("init")
        run("app", "set", "Spotify", "favourite")
        run("app", "set", "com.google.Chrome", "flat")
        XCTAssertEqual(run("app", "rm", "google chrome").exitCode, 0)
        XCTAssertEqual(run("app", "rm", "COM.SPOTIFY.CLIENT").exitCode, 0)
        XCTAssertNil(try context.store.load().apps)
        let missing = run("app", "rm", "Spotify")
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(missing.output.contains("no app rule for \"Spotify\""), missing.output)
    }

    func testPresetRenameCarriesItsRules() throws {
        run("init")
        run("app", "set", "Spotify", "favourite")
        run("preset", "rename", "favourite", "fav")
        XCTAssertEqual(try rules(), [AppRule(app: "com.spotify.client", preset: "fav")])
        run("preset", "rm", "fav")
        XCTAssertEqual(try rules(), [AppRule(app: "com.spotify.client", preset: "fav")], "a removed preset leaves its rule, which matches nothing")
    }

    func testDryRunShowsTheRuleAndTheFlagAndWritesNothing() throws {
        run("init")
        run("app", "set", "Spotify", "favourite")
        let before = try Data(contentsOf: context.store.url)
        let set = run("app", "set", "Google Chrome", "flat", "--dry-run")
        XCTAssertEqual(set.exitCode, 0, set.output)
        XCTAssertTrue(set.output.contains("app rules before: com.spotify.client → favourite"), set.output)
        XCTAssertTrue(set.output.contains("app rules after:  com.spotify.client → favourite, com.google.Chrome → flat"), set.output)
        XCTAssertTrue(run("app", "on", "--dry-run").output.contains("apps off → on"))
        XCTAssertTrue(run("app", "rm", "Spotify", "--dry-run").output.contains("app rules after:  none"))
        let report = try json("app", "on", "--dry-run")
        XCTAssertEqual((report["after"] as? [String: Any])?["followsApps"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: context.store.url), before)
        XCTAssertEqual(run("app", "list", "--dry-run").exitCode, 2)
    }

    func testShowAndStatusSayWhichCurveIsHeard() throws {
        run("init")
        try writeStatus(AppsStatus(listening: true, overlay: spotify, held: nil, lastMatch: spotify, lastMatchAt: Date()))
        let show = CLI.run([], context: context)
        XCTAssertTrue(show.output.contains("MacBook Pro Speakers (own profile"), show.output)
        XCTAssertTrue(show.output.contains("app: Spotify → favourite — heard instead of the device's curve until Spotify stops"), show.output)
        XCTAssertEqual((try json()["app"] as? [String: String])?["name"], "Spotify")
        XCTAssertTrue(run("status").output.contains("app: Spotify → favourite"))

        try writeStatus(AppsStatus(listening: true, overlay: nil, held: spotify, lastMatch: spotify, lastMatchAt: Date()))
        XCTAssertTrue(CLI.run([], context: context).output.contains("app: Spotify plays — your edit is heard until it stops"), CLI.run([], context: context).output)

        try writeStatus(nil)
        XCTAssertFalse(CLI.run([], context: context).output.contains("app:"))
        XCTAssertNil(try json()["app"])
    }

    func testCompleteListsAudioAppsAndRuleApps() {
        run("init")
        run("app", "set", "Music", "flat")
        XCTAssertEqual(run("__complete", "apps").output, "com.apple.Music\ncom.google.Chrome\ncom.spotify.client")
    }

    func testHelpHasItsOwnGroupAndFormsWrite() {
        let help = run("app", "--help").output
        XCTAssertTrue(help.contains("eq app set <app> <preset>"), help)
        XCTAssertFalse(help.contains("eq preset save"))
        XCTAssertTrue(run("--help").output.contains("\napp\n"))
        XCTAssertEqual(CommandHelp.form(matching: ["app", "set", "x", "y"])?.writes, true)
        XCTAssertEqual(CommandHelp.form(matching: ["app", "on"])?.writes, true)
        XCTAssertEqual(CommandHelp.form(matching: ["app"])?.writes, false)
        let set = Completions.specs.first { $0.key == "app set" }
        XCTAssertEqual(set?.operands, [.apps, .presets])
    }
}

final class AppDoctorTests: XCTestCase {
    private let spotify = AppMatch(app: "com.spotify.client", name: "Spotify", preset: "favourite")

    private func config(_ rules: [AppRule]) -> Config {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.apps = rules
        config.setFollowsApps(true)
        return config
    }

    private func live(_ apps: AppsStatus?) -> Status {
        Status(state: .running, device: nil, sampleRate: 48000, profile: .device, framesProcessed: 0, callbacks: 0, writes: 1,
               enabled: true, error: nil, pid: getpid(), version: Build.version, updatedAt: Date(), apps: apps)
    }

    func testTheRowSaysWhatIsHeardOrWhenItLastMatched() {
        let rules = config([AppRule(app: spotify.app, preset: "favourite")])
        let now = Date(timeIntervalSince1970: 10_000)
        let heard = Doctor.appsCheck(rules, live(AppsStatus(listening: true, overlay: spotify, held: nil, lastMatch: spotify, lastMatchAt: now)), now: now)
        XCTAssertEqual(heard, DoctorCheck(name: "apps", ok: true, detail: "listening, 1 rule; heard now: Spotify → favourite", warning: false))
        let earlier = Doctor.appsCheck(rules, live(AppsStatus(listening: true, overlay: nil, held: nil, lastMatch: spotify, lastMatchAt: now - 300)), now: now)
        XCTAssertEqual(earlier.detail, "listening, 1 rule; last match Spotify → favourite 5 min ago")
        XCTAssertEqual(Doctor.appsCheck(rules, live(AppsStatus(listening: true))).detail, "listening, 1 rule; no match yet")
    }

    func testTheRowWarnsAboutAMissingPresetDeafListenersOrAnOldDaemon() {
        let broken = Doctor.appsCheck(config([AppRule(app: "com.x", preset: "gone")]), live(AppsStatus(listening: false)))
        XCTAssertTrue(broken.warning)
        XCTAssertTrue(broken.detail.contains("com.x: no preset \"gone\""), broken.detail)
        XCTAssertTrue(broken.detail.contains("cannot listen"), broken.detail)
        XCTAssertTrue(Doctor.appsCheck(config([]), nil).detail.contains("no rules"))
        XCTAssertTrue(Doctor.appsCheck(config([AppRule(app: spotify.app, preset: "flat")]), live(nil)).detail.contains("does not follow apps"))
    }

    func testTheRowAppearsOnlyWhileTheFeatureIsOn() {
        var probes = DoctorProbes(osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0) },
                                  loadConfig: { Config.initial(builtInUID: nil, builtInName: nil) }, readStatus: { nil },
                                  defaultOutput: { nil }, launcher: { .notRegistered }, executablePath: { _ in nil }, signalStatus: { _ in false },
                                  sleep: { _ in }, smoke: true)
        XCTAssertFalse(Doctor.run(probes).checks.contains { $0.name == "apps" })
        probes.loadConfig = { self.config([AppRule(app: "com.spotify.client", preset: "favourite")]) }
        XCTAssertEqual(Doctor.run(probes).checks.map(\.name).prefix(4), ["macOS", "config", "hooks", "apps"])
    }
}

final class AppWatchHeaderTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    func testTheHeaderNamesTheAppInsteadOfTheDevicePreset() {
        var frame = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: Array(repeating: -60, count: 10), out: Array(repeating: -6, count: 10),
                               peak: -6, limiting: false, gains: Array(repeating: 0, count: 10), preamp: 0, enabled: true)
        let layout = WatchLayout.fit(cols: 120, rows: 24)
        let plain = Watch.frame(frame, layout: layout, preset: ("night", false), preference: Preference(bass: 3))[0]
        XCTAssertTrue(plain.contains("night") && plain.contains("bass +3"), plain)
        frame.app = AppMatch(app: "com.spotify.client", name: "Spotify", preset: "favourite")
        let heard = Watch.frame(frame, layout: layout, preset: ("night", false), preference: Preference(bass: 3))[0]
        XCTAssertTrue(heard.contains("app: Spotify → favourite"), heard)
        XCTAssertFalse(heard.contains("night") || heard.contains("bass"), heard)
    }
}
